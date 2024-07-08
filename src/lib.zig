const std = @import("std");
const assert = std.debug.assert;

pub const UringJob = @import("job.zig").UringJob;
pub const Pool = @import("pool.zig").Pool;

pub const Response = @import("tcp/http/lib.zig").Response;
pub const Request = @import("tcp/http/lib.zig").Request;
pub const KVPair = @import("tcp/http/lib.zig").KVPair;

pub const zzzOptions = struct {
    allocator: std.mem.Allocator,
    version: std.http.Version = .@"HTTP/1.1",
    kernel_backlog: u31 = 1024,
    uring_entries: u16 = 256,
    size_request_header: usize = 1024 * 4,
    size_read_buffer: usize = 512,
};

// TODO: Maybe update this so that it is a comptime fn and the zzz instance
// has all of its settings burned in.
pub const zzz = struct {
    const Self = @This();
    options: zzzOptions,
    socket: ?std.posix.socket_t = null,

    /// Initalize an instance of zzz.
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
        try std.posix.listen(zzz_socket, self.options.kernel_backlog);

        const allocator = self.options.allocator;

        // Create our Ring.
        var uring = try std.os.linux.IoUring.init(
            self.options.uring_entries,
            std.os.linux.IORING_SETUP_COOP_TASKRUN | std.os.linux.IORING_SETUP_SINGLE_ISSUER,
        );
        defer uring.deinit();

        // Create a buffer of Completion Queue Events to copy into.
        var cqes = [_]std.os.linux.io_uring_cqe{undefined} ** 1024;

        // What if we had a set of "pools"?
        // Like a generic pool interface that allows you to initalize
        var buffer_pool = Pool([1024]u8, 1024).init(null, .{});
        var job_pool = Pool(UringJob, 1024).init(null, .{});
        var request_pool = Pool(std.ArrayList(u8), 1024).init(struct {
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

                        // Empty it out!
                        //
                        // Consideration: What if we have a request come in that tries to use a request ArrayList
                        // that is already being used for a connection? We should have a way to prevent these collisions.
                        // We are basically doing a very primitive hash table that is array backed. Might be worth it to
                        // include some sort of collision prevention.
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
                                // This is the end of the headers.
                                //std.debug.print("Request: {s}\n", .{inner.request.items});

                                // This is where the request header should be parsed.
                                //
                                //
                                // we need to decide what to do regarding the request body?
                                // different bodies need to parsed differently, depending on "Content-Type" header.
                                //
                                // if application/xx

                                var resp = Response(.{ .headers_size = 1 }).init(.OK);

                                // We can reuse the inner.buffer since the request is now fully parsed and we can use it to send the response.
                                const response = try resp.respond_into_buffer(@embedFile("sample.html"), inner.buffer);
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
