const std = @import("std");
const builtin = @import("builtin");
const zzz = @import("lib.zig").zzz;

const stdout = std.io.getStdOut().writer();
const Response = @import("response.zig").Response;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    //var z3 = try zzz.init(host, port, .{ .kernel_backlog = 4096 });
    //defer z3.deinit();
    //try z3.bind();
    //try z3.listen();

    const addr = try std.net.Address.resolveIp(host, port);

    std.log.debug("zzz listening...", .{});

    const server_socket = blk: {
        const socket_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
        break :blk try std.posix.socket(addr.any.family, socket_flags, std.posix.IPPROTO.TCP);
    };

    if (@hasDecl(std.posix.SO, "REUSEPORT_LB")) {
        try std.posix.setsockopt(server_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
    } else if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(server_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    } else {
        try std.posix.setsockopt(server_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    }

    {
        const socklen = addr.getOsSockLen();
        try std.posix.bind(server_socket, &addr.any, socklen);
    }

    try std.posix.listen(server_socket, 1024);

    const UringJobType = enum {
        Accept,
        Read,
        Write,
        Close,
    };

    const UringAccept = struct {
        allocator: *std.mem.Allocator,
    };

    const UringRead = struct {
        allocator: *std.mem.Allocator,
        socket: std.posix.socket_t,
        buffer: []u8,
        request: *std.ArrayList(u8),
    };

    const UringWrite = struct {
        allocator: *std.mem.Allocator,
        socket: std.posix.socket_t,
        response: []u8,
        write_count: i32,
    };

    const UringClose = struct {
        allocator: *std.mem.Allocator,
    };

    const UringJob = union(UringJobType) {
        Accept: UringAccept,
        Read: UringRead,
        Write: UringWrite,
        Close: UringClose,
    };

    const allocator = std.heap.c_allocator;
    //var uring = try std.os.linux.IoUring.init(256, 0);
    var params = std.mem.zeroInit(std.os.linux.io_uring_params, .{
        .flags = std.os.linux.IORING_SETUP_SQPOLL,
        .features = 0,
        .sq_thread_idle = 500,
    });

    var uring = try std.os.linux.IoUring.init_params(256, &params);

    var address: std.net.Address = undefined;
    var address_len: std.posix.socklen_t = @sizeOf(std.net.Address);

    const job: *UringJob = try allocator.create(UringJob);
    job.* = .{ .Accept = .{ .allocator = @constCast(&allocator) } };

    _ = try uring.accept_multishot(@as(u64, @intFromPtr(job)), server_socket, &address.any, &address_len, 0);
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
                        const buffer = try inner.allocator.alloc(u8, 16);
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

                            // This is where we will match a router.
                            // Generate Response.
                            var resp = Response.init(.OK);
                            resp.add_header(.{ .key = "Server", .value = "zzz (z3)" });
                            resp.add_header(.{ .key = "Connection", .value = "close" });

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
                            j.* = .{ .Write = .{ .allocator = inner.allocator, .socket = inner.socket, .response = inner.response, .write_count = inner.write_count + write_count } };
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
}
