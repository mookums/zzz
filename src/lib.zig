const std = @import("std");
pub const Response = @import("response.zig").Response;
pub const Version = @import("util.zig").Version;
pub const UringJob = @import("job.zig").UringJob;

pub const zzzOptions = struct {
    allocator: std.mem.Allocator,
    version: Version = .@"HTTP/1.1",
    kernel_backlog: u31 = 1024,
    uring_entries: u16 = 256,
    maximum_request_header_size: usize = 1024 * 4,
};

pub const zzz = struct {
    const Self = @This();
    options: zzzOptions,
    addr: std.net.Address,
    socket: std.posix.socket_t = undefined,

    /// Create a zzz server, attaching
    pub fn init(name: []const u8, port: u16, options: zzzOptions) !Self {
        const addr = try std.net.Address.resolveIp(name, port);
        std.log.debug("initializing zzz on {s}:{d}", .{ name, port });

        return Self{ .addr = addr, .options = options };
    }

    pub fn deinit(self: *Self) void {
        if (self.socket != undefined) {
            std.posix.close(self.socket);
        }
    }

    pub fn bind(self: *Self) !void {
        self.socket = blk: {
            const socket_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
            break :blk try std.posix.socket(self.addr.any.family, socket_flags, std.posix.IPPROTO.TCP);
        };

        if (@hasDecl(std.posix.SO, "REUSEPORT_LB")) {
            try std.posix.setsockopt(self.socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
        } else if (@hasDecl(std.posix.SO, "REUSEPORT")) {
            try std.posix.setsockopt(self.socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
        } else {
            try std.posix.setsockopt(self.socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        }

        {
            const socklen = self.addr.getOsSockLen();
            try std.posix.bind(self.socket, &self.addr.any, socklen);
        }
    }

    pub fn listen(self: *Self) !void {
        std.log.debug("zzz listening...", .{});
        try std.posix.listen(self.socket, self.options.kernel_backlog);

        const allocator = self.options.allocator;
        //var uring = try std.os.linux.IoUring.init(256, 0);
        var params = std.mem.zeroInit(std.os.linux.io_uring_params, .{
            .flags = std.os.linux.IORING_SETUP_SQPOLL,
            .features = 0,
            .sq_thread_idle = 1000,
        });

        var uring = try std.os.linux.IoUring.init_params(self.options.uring_entries, &params);

        var address: std.net.Address = undefined;
        var address_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        const job: *UringJob = try allocator.create(UringJob);
        errdefer self.options.allocator.destroy(job);

        job.* = .{ .Accept = .{ .allocator = @constCast(&allocator) } };

        _ = try uring.accept_multishot(@as(u64, @intFromPtr(job)), self.socket, &address.any, &address_len, 0);
        _ = try uring.submit();

        // Event Loop to die for...
        while (true) {
            const rd_count = uring.cq_ready();
            if (rd_count > 0) {
                for (0..rd_count) |_| {
                    const cqe = try uring.copy_cqe();
                    const j: *UringJob = @ptrFromInt(cqe.user_data);

                    //std.debug.print("Current Job: {s}\n", .{@tagName(j.*)});

                    switch (j.*) {
                        .Accept => |inner| {
                            const socket: std.posix.socket_t = cqe.res;
                            const buffer = try inner.allocator.alloc(u8, 64);
                            const read_buffer = .{ .buffer = buffer };

                            // Create the ArrayList for the Request to get read into.
                            const request = try inner.allocator.create(std.ArrayList(u8));
                            request.* = std.ArrayList(u8).init(inner.allocator.*);

                            const new_job: *UringJob = try allocator.create(UringJob);
                            new_job.* = .{ .Read = .{ .allocator = inner.allocator, .socket = socket, .buffer = buffer, .request = request } };
                            _ = try uring.read(@as(u64, @intFromPtr(new_job)), socket, read_buffer, 0);
                        },

                        .Read => |inner| {
                            const read_count = cqe.res;
                            // Append the read chunk into our total request.
                            try inner.request.appendSlice(inner.buffer[0..@intCast(read_count)]);

                            if (read_count == 0) {
                                inner.allocator.free(inner.buffer);
                                inner.request.deinit();
                                inner.allocator.destroy(inner.request);
                                j.* = .{ .Close = .{ .allocator = inner.allocator } };
                                _ = try uring.close(@as(u64, @intFromPtr(j)), inner.socket);
                                continue;
                            }

                            // This can probably be faster.
                            if (std.mem.endsWith(u8, inner.request.items, "\r\n\r\n")) {
                                // Free the inner read buffer. We have it all in inner.request now.
                                inner.allocator.free(inner.buffer);

                                // Parse the Request here.
                                const RequestLineParsing = enum {
                                    Method,
                                    Host,
                                    Version,
                                };

                                const HeaderParsing = enum {
                                    Name,
                                    Value,
                                };

                                const ParsingStages = enum {
                                    RequestLine,
                                    Headers,
                                };

                                const Parsing = union(ParsingStages) {
                                    RequestLine: RequestLineParsing,
                                    Headers: HeaderParsing,
                                };

                                var stage: Parsing = .{ .RequestLine = .Method };

                                var start: usize = 0;
                                var no_bytes_left = false;
                                no_bytes_left = false;

                                parse: for (0..self.options.maximum_request_header_size) |i| {
                                    // Our byte is either valid or we set the no_bytes_left flag.
                                    const byte = blk: {
                                        if (i < inner.request.items.len) {
                                            break :blk inner.request.items[i];
                                        } else {
                                            no_bytes_left = true;
                                            break :blk 0;
                                        }
                                    };

                                    switch (stage) {
                                        .RequestLine => |rl| {
                                            if (std.ascii.isWhitespace(byte) or no_bytes_left) {
                                                switch (rl) {
                                                    .Method => {
                                                        std.debug.print("Matched Method: {s}\n", .{inner.request.items[start..i]});
                                                        start = i + 1;
                                                        stage = .{ .RequestLine = .Host };
                                                    },

                                                    .Host => {
                                                        std.debug.print("Matched Host: {s}\n", .{inner.request.items[start..i]});
                                                        start = i + 1;
                                                        stage = .{ .RequestLine = .Version };
                                                    },

                                                    .Version => {
                                                        std.debug.print("Matched Version: {s}\n", .{inner.request.items[start..i]});
                                                        start = i;
                                                        stage = .{ .Headers = .Name };
                                                    },
                                                }
                                            }
                                        },

                                        .Headers => |h| {
                                            if (byte == ':' or byte == '\n' or no_bytes_left) {
                                                switch (h) {
                                                    .Name => {
                                                        if (byte != ':') {
                                                            break :parse;
                                                        }

                                                        //std.debug.print("Matched Header Key!\n", .{});
                                                        stage = .{ .Headers = .Value };
                                                    },
                                                    .Value => {
                                                        //std.debug.print("Matched Header Value!\n", .{});
                                                        stage = .{ .Headers = .Name };
                                                    },
                                                }
                                            }
                                        },
                                    }
                                }

                                // This is where we will match a router.
                                // Generate Response.
                                var resp = Response.init(.OK);

                                const file = @embedFile("sample.html");
                                const buffer = try resp.respond_into_alloc(file, inner.allocator.*, 512);

                                // Free the inner.request since we already used it.
                                inner.request.deinit();
                                inner.allocator.destroy(inner.request);

                                j.* = .{ .Write = .{ .allocator = inner.allocator, .socket = inner.socket, .response = buffer, .write_count = 0 } };
                                _ = try uring.write(@as(u64, @intFromPtr(j)), inner.socket, buffer, 0);
                            } else {
                                _ = try uring.read(@as(u64, @intFromPtr(j)), inner.socket, .{ .buffer = inner.buffer }, 0);
                            }
                        },

                        .Write => |inner| {
                            const write_count = cqe.res;

                            if (inner.write_count + write_count == inner.response.len) {
                                // Close, we are done.
                                inner.allocator.free(inner.response);
                                j.* = .{ .Close = .{ .allocator = inner.allocator } };
                                _ = try uring.close(@as(u64, @intFromPtr(j)), inner.socket);
                            } else {
                                // Keep writing.
                                j.* = .{ .Write = .{
                                    .allocator = inner.allocator,
                                    .socket = inner.socket,
                                    .response = inner.response,
                                    .write_count = inner.write_count + write_count,
                                } };
                                _ = try uring.write(@as(u64, @intFromPtr(j)), inner.socket, inner.response, @intCast(inner.write_count));
                            }
                        },

                        .Close => |inner| {
                            inner.allocator.destroy(j);
                        },
                    }
                }

                _ = try uring.submit();
            }
        }

        //while (true) {
        //    var address: std.net.Address = undefined;
        //    var address_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        //    const socket = std.posix.accept(self.socket, &address.any, &address_len, std.posix.SOCK.CLOEXEC) catch continue;
        //    errdefer std.posix.close(socket);

        //    const stream: std.net.Stream = .{ .handle = socket };
        //    defer stream.close();

        //    var buf_reader = std.io.bufferedReader(stream.reader());
        //    const reader = buf_reader.reader();

        //    var buf_writer = std.io.bufferedWriter(stream.writer());
        //    defer buf_writer.flush() catch {};
        //    const writer = buf_writer.writer();

        //    const RequestLineParsing = enum {
        //        Method,
        //        Host,
        //        Version,
        //    };

        //    const HeaderParsing = enum {
        //        Name,
        //        Value,
        //    };

        //    const ParsingStages = enum {
        //        RequestLine,
        //        Headers,
        //    };

        //    const Parsing = union(ParsingStages) {
        //        RequestLine: RequestLineParsing,
        //        Headers: HeaderParsing,
        //    };

        //    var stage: Parsing = .{ .RequestLine = .Method };

        //    var no_bytes_left = false;
        //    parse: while (true) {
        //        const byte = reader.readByte() catch blk: {
        //            no_bytes_left = true;
        //            break :blk 0;
        //        };

        //        switch (stage) {
        //            .RequestLine => |rl| {
        //                if (std.ascii.isWhitespace(byte) or no_bytes_left) {
        //                    switch (rl) {
        //                        .Method => {
        //                            //std.debug.print("Matched Method!\n", .{});
        //                            stage = .{ .RequestLine = .Version };
        //                        },

        //                        .Version => {
        //                            //std.debug.print("Matched Version!\n", .{});
        //                            stage = .{ .RequestLine = .Host };
        //                        },

        //                        .Host => {
        //                            //std.debug.print("Matched Host!\n", .{});
        //                            stage = .{ .Headers = .Name };
        //                        },
        //                    }
        //                }
        //            },

        //            .Headers => |h| {
        //                if (byte == ':' or byte == '\n' or no_bytes_left) {
        //                    switch (h) {
        //                        .Name => {
        //                            if (byte != ':') {
        //                                break :parse;
        //                            }

        //                            //std.debug.print("Matched Header Key!\n", .{});
        //                            stage = .{ .Headers = .Value };
        //                        },
        //                        .Value => {
        //                            //std.debug.print("Matched Header Value!\n", .{});
        //                            stage = .{ .Headers = .Name };
        //                        },
        //                    }
        //                }
        //            },
        //        }
        //    }

        //    const file = @embedFile("./sample.html");
        //    var resp = Response.init(.OK);
        //    resp.add_header(.{ .key = "Server", .value = "zzz (z3)" });

        //    if (self.options.version == .@"HTTP/1.1") {
        //        resp.add_header(.{ .key = "Connection", .value = "close" });
        //    }

        //    resp.respond(file, writer) catch return;
        //}
    }
};
