const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/tcp/http/server");

const Pool = @import("core").Pool;
const UringJob = @import("core").UringJob;

const Router = @import("router.zig").Router;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Mime = @import("mime.zig").Mime;
const Context = @import("context.zig").Context;

pub const ServerConfig = struct {
    /// The allocator that server will use.
    allocator: std.mem.Allocator,
    /// Kernel Backlog Value.
    size_backlog_kernel: u31 = 512,
    /// Number of Maximum Concurrnet Connections.
    ///
    /// zzz will drop/close any connections greater
    /// than this.
    ///
    /// You want to tune this to your expected number
    /// of maximum connections.
    ///
    /// Default: 1024.
    size_connections_max: u16 = 1024,
    /// Amount of allocated memory retained
    /// after an arena is cleared.
    ///
    /// A higher value will increase memory usage but
    /// should make allocators faster.
    ///
    /// A lower value will reduce memory usage but
    /// will make allocators slower.
    ///
    /// Default: 1KB.
    size_context_arena_retain: u32 = 1024,
    /// Maximum size (in bytes) of the Request.
    /// Default: 2MB.
    size_request_max: u32 = 1024 * 1024 * 2,
    /// Size of the Read Buffer for reading out of the Socket.
    /// Default: 512 B.
    size_read_buffer: u32 = 512,
    /// Size of the Read Buffer for writing into the Socket.
    /// Default: 512 B.
    size_write_buffer: u32 = 512,
    /// Maximum number of headers per Response.
    response_headers_max: u8 = 8,
};

pub const Server = struct {
    config: ServerConfig,
    router: Router,
    socket: ?std.posix.socket_t = null,
    connections: u32 = 0,

    pub fn init(config: ServerConfig, router: Router) Server {
        // Must be a power of 2.
        assert(config.size_connections_max % 2 == 0);

        return Server{
            .config = config,
            .router = router,
            .connections = 0,
        };
    }

    pub fn deinit(self: *Server) void {
        if (self.socket) |socket| {
            std.posix.close(socket);
        }

        self.router.deinit();
    }

    pub fn bind(self: *Server, name: []const u8, port: u16) !void {
        assert(name.len > 0);
        assert(port > 0);
        defer assert(self.socket != null);

        const addr = try std.net.Address.resolveIp(name, port);
        log.info("binding zzz server on {s}:{d}", .{ name, port });

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

    pub fn listen(self: *Server) !void {
        assert(self.socket != null);
        const server_socket = self.socket.?;
        defer std.posix.close(server_socket);

        log.info("server listening...", .{});
        try std.posix.listen(server_socket, self.config.size_backlog_kernel);

        const allocator = self.config.allocator;

        // Create our Ring.
        var uring = try std.os.linux.IoUring.init(
            self.config.size_connections_max,
            std.os.linux.IORING_SETUP_COOP_TASKRUN | std.os.linux.IORING_SETUP_SINGLE_ISSUER,
        );
        defer uring.deinit();

        // Create a buffer of Completion Queue Events to copy into.
        var cqes = try Pool(std.os.linux.io_uring_cqe).init(allocator, self.config.size_connections_max, null, null);
        defer cqes.deinit(null, null);

        var read_buffer_pool = try Pool([]u8).init(allocator, self.config.size_connections_max, struct {
            fn init_hook(buffer: [][]u8, info: anytype) void {
                for (buffer) |*item| {
                    // There is no handling this failure. If this happens, we need to crash.
                    item.* = info.allocator.alloc(u8, info.size) catch unreachable;
                }
            }
        }.init_hook, .{ .allocator = allocator, .size = self.config.size_read_buffer });

        defer read_buffer_pool.deinit(struct {
            fn deinit_hook(buffer: [][]u8, a: anytype) void {
                for (buffer) |item| {
                    a.free(item);
                }
            }
        }.deinit_hook, allocator);

        var job_pool = try Pool(UringJob).init(allocator, self.config.size_connections_max, null, null);
        defer job_pool.deinit(null, null);

        var request_pool = try Pool(std.ArrayList(u8)).init(allocator, self.config.size_connections_max, struct {
            fn init_hook(buffer: []std.ArrayList(u8), a: anytype) void {
                for (buffer) |*item| {
                    item.* = std.ArrayList(u8).initCapacity(a, 512) catch unreachable;
                }
            }
        }.init_hook, allocator);

        // Only needed since we do some allocations within the init hook.
        defer request_pool.deinit(struct {
            fn deinit_hook(buffer: []std.ArrayList(u8), _: anytype) void {
                for (buffer) |item| {
                    item.deinit();
                }
            }
        }.deinit_hook, null);

        // These arenas are passed down to the handlers so they can do whatever allocations and logic needed.
        var arena_pool = try Pool(std.heap.ArenaAllocator).init(allocator, self.config.size_connections_max, struct {
            fn init_hook(buffer: []std.heap.ArenaAllocator, a: anytype) void {
                for (buffer) |*item| {
                    item.* = std.heap.ArenaAllocator.init(a);
                }
            }
        }.init_hook, allocator);

        defer arena_pool.deinit(struct {
            fn deinit_hook(buffer: []std.heap.ArenaAllocator, _: anytype) void {
                for (buffer) |item| {
                    item.deinit();
                }
            }
        }.deinit_hook, null);

        // Create and send the first Job.
        const job: UringJob = .Accept;
        _ = try uring.accept(@as(u64, @intFromPtr(&job)), server_socket, null, null, 0);

        while (true) {
            const rd_count = try uring.copy_cqes(cqes.items[0..], 0);

            for (0..rd_count) |i| {
                const cqe = cqes.items[i];
                const j: *UringJob = @ptrFromInt(cqe.user_data);

                switch (j.*) {
                    .Accept => {
                        const socket: std.posix.socket_t = cqe.res;

                        if (self.connections >= self.config.size_connections_max) {
                            std.posix.close(socket);
                            continue;
                        }

                        self.connections += 1;

                        // Context Arena, not used by zzz but
                        // it is passed to the request handlers
                        // and used later on.
                        const arena = arena_pool.get_ptr(@mod(
                            @as(usize, @intCast(cqe.res)),
                            arena_pool.items.len,
                        ));

                        const buffer = read_buffer_pool.get(@mod(
                            @as(usize, @intCast(cqe.res)),
                            read_buffer_pool.items.len,
                        ));
                        const read_buffer = .{ .buffer = buffer };

                        // Create the ArrayList for the Request to get read into.
                        // TODO: This will need to be fixed at some point. This is our ONLY
                        // source of runtime allocation and should not exist.
                        const request = request_pool.get_ptr(
                            @mod(@as(usize, @intCast(cqe.res)), request_pool.items.len),
                        );

                        const new_job: *UringJob = job_pool.get_ptr(
                            @mod(@as(usize, @intCast(cqe.res)), job_pool.items.len),
                        );

                        new_job.* = .{ .Read = .{
                            .socket = socket,
                            .arena = arena,
                            .buffer = buffer,
                            .request = request,
                        } };

                        _ = try uring.recv(@as(u64, @intFromPtr(new_job)), socket, read_buffer, 0);
                    },

                    .Read => |inner| {
                        const read_count = cqe.res;

                        if (read_count > 0) {
                            try inner.request.appendSlice(inner.buffer[0..@as(usize, @intCast(read_count))]);
                            if (std.mem.endsWith(u8, inner.request.items, "\r\n\r\n")) {
                                //// This is the end of the headers.
                                const request = try Request.parse(.{
                                    .request_max_size = self.config.size_request_max,
                                }, inner.request.items);

                                // Clear and free it out, allowing us to handle future requests.
                                inner.request.items.len = 0;

                                const response = blk: {
                                    const route = self.router.get_route_from_host(request.host);
                                    if (route) |r| {
                                        const context: Context = Context.init(inner.arena.allocator(), request.host);
                                        const handler = r.get_handler(request.method);

                                        if (handler) |func| {
                                            const resp = func(request, context);
                                            break :blk try resp.respond_into_buffer(inner.buffer);
                                        } else {
                                            const resp = Response.init(.@"Method Not Allowed", Mime.HTML, "");
                                            break :blk try resp.respond_into_buffer(inner.buffer);
                                        }
                                    }

                                    // Default Response.
                                    var resp = Response.init(.@"Not Found", Mime.HTML, "");
                                    break :blk try resp.respond_into_buffer(inner.buffer);
                                };

                                j.* = .{ .Write = .{
                                    .socket = inner.socket,
                                    .arena = inner.arena,
                                    .response = response,
                                    .write_count = 0,
                                } };
                                _ = try uring.send(cqe.user_data, inner.socket, response, 0);
                            } else {
                                _ = try uring.recv(cqe.user_data, inner.socket, .{ .buffer = inner.buffer }, 0);
                            }
                        } else {
                            _ = inner.arena.reset(.{ .retain_with_limit = self.config.size_context_arena_retain });
                            self.connections -= 1;
                        }
                    },

                    .Write => |inner| {
                        const write_count = cqe.res;
                        _ = write_count;
                        const buffer = read_buffer_pool.get(
                            @mod(@as(usize, @intCast(inner.socket)), read_buffer_pool.items.len),
                        );
                        const request = request_pool.get_ptr(
                            @mod(@as(usize, @intCast(inner.socket)), request_pool.items.len),
                        );

                        j.* = .{ .Read = .{ .socket = inner.socket, .arena = inner.arena, .buffer = buffer, .request = request } };
                        _ = try uring.recv(cqe.user_data, inner.socket, .{ .buffer = buffer }, 0);
                    },

                    .Close => {},
                }
            }

            if (self.connections < self.config.size_connections_max) {
                _ = try uring.accept(@as(u64, @intFromPtr(&job)), server_socket, null, null, 0);
            }

            _ = try uring.submit_and_wait(1);
            assert(uring.cq_ready() >= 1);
        }

        unreachable;
    }
};
