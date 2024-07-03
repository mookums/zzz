const std = @import("std");
pub const Response = @import("response.zig").Response;
pub const Version = @import("util.zig").Version;

pub const zzzOptions = struct {
    version: Version = .@"HTTP/1.1",
    kernel_backlog: u31 = 1024,
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

        while (true) {
            var address: std.net.Address = undefined;
            var address_len: std.posix.socklen_t = @sizeOf(std.net.Address);

            const socket = std.posix.accept(self.socket, &address.any, &address_len, std.posix.SOCK.CLOEXEC) catch continue;
            errdefer std.posix.close(socket);

            const stream: std.net.Stream = .{ .handle = socket };
            defer stream.close();

            var buf_reader = std.io.bufferedReader(stream.reader());
            const reader = buf_reader.reader();

            var buf_writer = std.io.bufferedWriter(stream.writer());
            defer buf_writer.flush() catch {};
            const writer = buf_writer.writer();

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

            var no_bytes_left = false;
            parse: while (true) {
                const byte = reader.readByte() catch blk: {
                    no_bytes_left = true;
                    break :blk 0;
                };

                switch (stage) {
                    .RequestLine => |rl| {
                        if (std.ascii.isWhitespace(byte) or no_bytes_left) {
                            switch (rl) {
                                .Method => {
                                    //std.debug.print("Matched Method!\n", .{});
                                    stage = .{ .RequestLine = .Version };
                                },

                                .Version => {
                                    //std.debug.print("Matched Version!\n", .{});
                                    stage = .{ .RequestLine = .Host };
                                },

                                .Host => {
                                    //std.debug.print("Matched Host!\n", .{});
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

            const file = @embedFile("./sample.html");
            var resp = Response.init(.OK);
            resp.add_header(.{ .key = "Server", .value = "zzz (z3)" });

            if (self.options.version == .@"HTTP/1.1") {
                resp.add_header(.{ .key = "Connection", .value = "close" });
            }

            resp.respond(file, writer) catch return;
        }
    }
};
