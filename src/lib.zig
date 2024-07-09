const std = @import("std");
const assert = std.debug.assert;

pub const UringJob = @import("job.zig").UringJob;
pub const Pool = @import("pool.zig").Pool;

pub const Response = @import("tcp/http/lib.zig").Response;
pub const Request = @import("tcp/http/lib.zig").Request;
pub const KVPair = @import("tcp/http/lib.zig").KVPair;
pub const Mime = @import("tcp/http/lib.zig").Mime;

/// This is provided at compile time so that we can
/// create correctly sized buffers.
pub const zzzConfig = struct {
    /// Kernel Backlog Value.
    kernel_backlog: u31 = 1024,
    /// Number of Uring Entries.
    uring_entries: u16 = 256,
    /// Maximum size (in bytes) of the Request header.
    size_request_header_max: usize = 1024 * 4,
    /// Size of the Read Buffer for reading out of the Socket.
    size_read_buffer: usize = 512,
    /// Maximum number of headers per Request.
    request_headers_max: usize = 32,
    /// Maximum number of headers per Response.
    response_headers_max: usize = 8,
};

/// This is provided at runtime so that we can do final
/// customizations on the zzz server.
pub const zzzOptions = struct {
    /// The allocator that zzz will use.
    allocator: std.mem.Allocator,
};

/// zzz is created with a compile-time config that decides the size of all of the buffers utilized.
/// This allows us to preallocate various buffers at compile-time.
///
/// An alternative to this could be using an allocator to allocate buffers at run-time, right before
/// the server starts up. This would allow us to only take in a runtime configuration and also support
/// exporting as a C library. Think about this.
pub fn zzz(comptime config: zzzConfig) type {
    return struct {
        const Self = @This();
        options: zzzOptions,
        socket: ?std.posix.socket_t = null,

        pub fn init(options: zzzOptions) Self {
            return Self{ .options = options };
        }

        pub fn deinit(self: *Self) void {
            if (self.socket) |socket| {
                std.posix.close(socket);
            }
        }

        pub fn bind(self: *Self, name: []const u8, port: u16) !void {
            assert(name.len > 0);
            assert(port > 0);
            defer assert(self.socket != null);

            const addr = try std.net.Address.resolveIp(name, port);
            std.log.debug("binding zzz on {s}:{d}", .{ name, port });

            const socket = blk: {
                const socket_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
                break :blk try std.posix.socket(
                    addr.any.family,
                    socket_flags,
                    std.posix.IPPROTO.TCP,
                );
            };

            if (@hasDecl(std.posix.SO, "REUSEPORT_LB")) {
                try std.posix.setsockopt(
                    socket,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.REUSEPORT_LB,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            } else if (@hasDecl(std.posix.SO, "REUSEPORT")) {
                try std.posix.setsockopt(
                    socket,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.REUSEPORT,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            } else {
                try std.posix.setsockopt(
                    socket,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.REUSEADDR,
                    &std.mem.toBytes(@as(c_int, 1)),
                );
            }

            self.socket = socket;
            try std.posix.bind(socket, &addr.any, addr.getOsSockLen());
        }

        pub fn listen(self: *Self) !void {
            assert(self.socket != null);
            const zzz_socket = self.socket.?;
            defer std.posix.close(zzz_socket);

            std.log.debug("zzz listening...", .{});
            try std.posix.listen(zzz_socket, config.kernel_backlog);

            const allocator = self.options.allocator;

            // Create our Ring.
            var uring = try std.os.linux.IoUring.init(
                config.uring_entries,
                std.os.linux.IORING_SETUP_COOP_TASKRUN | std.os.linux.IORING_SETUP_SINGLE_ISSUER,
            );
            defer uring.deinit();

            // Create a buffer of Completion Queue Events to copy into.
            var cqes = [_]std.os.linux.io_uring_cqe{undefined} ** config.uring_entries;

            // What if we had a set of "pools"?
            // Like a generic pool interface that allows you to initalize
            var buffer_pool = Pool([config.size_read_buffer]u8, config.uring_entries).init(null, .{});
            var job_pool = Pool(UringJob, config.uring_entries).init(null, .{});
            var request_pool = Pool(std.ArrayList(u8), config.uring_entries).init(struct {
                fn init_hook(buffer: []std.ArrayList(u8), a: anytype) void {
                    for (buffer) |*item| {
                        var list = std.ArrayList(u8).init(a);
                        // We pre-initalize some space in the ArrayList, this is
                        // so that we can prevent some allocations if we are only
                        // handling short requests (which most end up being).
                        list.ensureTotalCapacity(512) catch unreachable;
                        item.* = list;
                    }
                }
            }.init_hook, allocator);

            // Only needed since we do some allocations within the init hook.
            defer request_pool.deinit(struct {
                fn deinit_hook(buffer: []std.ArrayList(u8)) void {
                    for (buffer) |item| {
                        item.deinit();
                    }
                }
            }.deinit_hook);

            // Create and send the first Job.
            const job: UringJob = .{ .Accept = .{} };
            _ = try uring.accept_multishot(@as(u64, @intFromPtr(&job)), zzz_socket, null, null, 0);

            while (true) {
                const rd_count = try uring.copy_cqes(cqes[0..], 0);
                for (0..rd_count) |i| {
                    const cqe = cqes[i];
                    const j: *UringJob = @ptrFromInt(cqe.user_data);

                    switch (j.*) {
                        .Accept => {
                            const socket: std.posix.socket_t = cqe.res;
                            const buffer = buffer_pool.get(@mod(
                                @as(usize, @intCast(cqe.res)),
                                buffer_pool.items.len,
                            ));
                            const read_buffer = .{ .buffer = buffer };

                            // Create the ArrayList for the Request to get read into.
                            const request = request_pool.get(@mod(
                                @as(usize, @intCast(cqe.res)),
                                request_pool.items.len,
                            ));

                            if (request.items.len > 0) {
                                request.clearAndFree();
                            }

                            const new_job: *UringJob = job_pool.get(@mod(@as(usize, @intCast(cqe.res)), job_pool.items.len));
                            new_job.* = .{ .Read = .{ .socket = socket, .buffer = buffer, .request = request } };
                            _ = try uring.recv(@as(u64, @intFromPtr(new_job)), socket, read_buffer, 0);
                        },

                        .Read => |inner| {
                            const read_count = cqe.res;

                            if (read_count > 0) {
                                try inner.request.appendSlice(inner.buffer[0..@as(usize, @intCast(read_count))]);
                                if (std.mem.endsWith(u8, inner.request.items, "\r\n\r\n")) {
                                    // This chunk here all the way down to the clearAndFree is unacceptably slow.
                                    // We might need to bring back the WorkerPool and delegate jobs over to it.
                                    // These jobs would likely be parsing and routing...
                                    //
                                    // Another issue is that the clearAndFree is needed for Connection: keep-alive to work.
                                    //
                                    // We could try making a pool of Rings and running each loop in a thread? This would allow for more
                                    // tasks to be done at once BUT it might also make connections on the current ring lag.
                                    //
                                    // WorkerPool seems to be the best option where it can create new entires in the ring whenever.
                                    // But we are technically not supposed to share rings? soooo..... maybe message passing...
                                    //std.debug.print("Request: {s}\n", .{inner.request.items});

                                    //// This is the end of the headers.
                                    const request = try Request(.{
                                        .headers_size = config.request_headers_max,
                                        .request_max_size = config.size_request_header_max,
                                    }).parse(inner.request.items);
                                    _ = request;

                                    //std.debug.print("Host: {s}\n", .{request.host});
                                    //for (request.headers[0..request.headers_idx]) |kv| {
                                    //    std.debug.print("Key: {s} | Value: {s}\n", .{ kv.key, kv.value });
                                    //}
                                    //std.debug.print("\n", .{});

                                    // Clear and free it out, allowing us to handle future requests.
                                    inner.request.clearAndFree();

                                    // This is where we will send it to the router. Router will return our Response for us.
                                    // We will just send this response via our uring.

                                    var resp = Response(.{
                                        .headers_size = config.response_headers_max,
                                    }).init(.OK);
                                    // Temporary since keep-alive isn't working good rn.
                                    //try resp.add_header(.{ .key = "Connection", .value = "close" });

                                    // We can reuse the inner.buffer since the request is now fully parsed and we can use it to send the response.
                                    const response = try resp.respond_into_buffer(
                                        inner.buffer,
                                        @embedFile("sample.html"),
                                        Mime.HTML,
                                    );
                                    j.* = .{ .Write = .{ .socket = inner.socket, .response = response, .write_count = 0 } };

                                    _ = try uring.send(cqe.user_data, inner.socket, response, 0);
                                } else {
                                    _ = try uring.recv(cqe.user_data, inner.socket, .{ .buffer = inner.buffer }, 0);
                                }
                            }
                        },

                        .Write => |inner| {
                            const write_count = cqe.res;
                            _ = write_count;
                            const buffer = buffer_pool.get(@mod(@as(usize, @intCast(inner.socket)), buffer_pool.items.len));
                            const request = request_pool.get(@mod(@as(usize, @intCast(inner.socket)), request_pool.items.len));

                            j.* = .{ .Read = .{ .socket = inner.socket, .buffer = buffer, .request = request } };
                            _ = try uring.recv(cqe.user_data, inner.socket, .{ .buffer = buffer }, 0);
                        },

                        .Close => {},
                    }
                }

                _ = try uring.submit_and_wait(1);
            }
        }
    };
}
