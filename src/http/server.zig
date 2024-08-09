const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/server");

const Job = @import("core").Job;

const Pool = @import("pool.zig").Pool;

const Provision = @import("provision.zig").Provision;
const Router = @import("router.zig").Router;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Mime = @import("mime.zig").Mime;
const Context = @import("context.zig").Context;

const ServerThreadCount = union(enum) {
    auto,
    count: u32,
};

const ServerThreading = union(enum) {
    single_threaded,
    multi_threaded: ServerThreadCount,
};

pub const ServerConfig = struct {
    /// The allocator that server will use.
    allocator: std.mem.Allocator,
    /// Threading Model to use.
    ///
    /// Default: .single_threaded
    threading: ServerThreading = .single_threaded,
    /// Kernel Backlog Value.
    size_backlog_kernel: u31 = 512,
    /// Number of Maximum Concurrnet Connections.
    ///
    /// This is applied PER thread if using multi-threading.
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

    pub fn init(config: ServerConfig, router: Router) Server {
        // Must be a power of 2.
        assert(config.size_connections_max % 2 == 0);

        return Server{
            .config = config,
            .router = router,
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

    /// This function assumes that the socket is set up and
    /// is already listening.
    fn run(config: ServerConfig, router: Router, server_socket: std.posix.socket_t, uring: *std.os.linux.IoUring) !void {
        const allocator = config.allocator;
        defer uring.deinit();

        // Create a buffer of Completion Queue Events to copy into.
        var cqes = try Pool(std.os.linux.io_uring_cqe).init(allocator, config.size_connections_max, null, null);
        defer cqes.deinit(null, null);

        var provision_pool = try Pool(Provision).init(allocator, config.size_connections_max, struct {
            fn init_hook(provisions: []Provision, ctx: anytype) void {
                for (provisions) |*provision| {
                    provision.socket = undefined;
                    // Create Buffer
                    provision.buffer = ctx.allocator.alloc(u8, ctx.size_read_buffer) catch unreachable;
                    // Create Request ArrayList
                    provision.request = std.ArrayList(u8).initCapacity(ctx.allocator, ctx.size_read_buffer) catch unreachable;
                    // Create the Context Arena
                    provision.arena = std.heap.ArenaAllocator.init(ctx.allocator);
                }
            }
        }.init_hook, config);

        // we need to deinit the provision pool here.

        // Create and send the first Job.
        const first_provision = Provision{
            .job = .Accept,
            .index = undefined,
            .socket = undefined,
            .request = undefined,
            .arena = undefined,
            .buffer = undefined,
        };

        _ = try uring.accept(@as(u64, @intFromPtr(&first_provision)), server_socket, null, null, 0);

        while (true) {
            const rd_count = try uring.copy_cqes(cqes.items[0..], 0);

            for (0..rd_count) |i| {
                const cqe = cqes.items[i];
                const p: *Provision = @ptrFromInt(cqe.user_data);
                const j: Job = p.job;

                switch (j) {
                    .Accept => {
                        const socket: std.posix.socket_t = cqe.res;

                        const provision = provision_pool.borrow(@intCast(cqe.res)) catch {
                            std.posix.close(socket);
                            continue;
                        };

                        // Store the index of this item.
                        provision.item.index = provision.index;
                        provision.item.socket = socket;

                        const read_buffer = .{ .buffer = provision.item.buffer };

                        provision.item.job = .Read;
                        _ = try uring.recv(@as(u64, @intFromPtr(provision.item)), socket, read_buffer, 0);
                    },

                    .Read => {
                        const read_count = cqe.res;

                        if (read_count > 0) {
                            try p.request.appendSlice(p.buffer[0..@as(usize, @intCast(read_count))]);
                            if (std.mem.endsWith(u8, p.request.items, "\r\n\r\n")) {
                                //// This is the end of the headers.
                                const request = try Request.parse(.{
                                    .request_max_size = config.size_request_max,
                                }, p.request.items);

                                // Clear and free it out, allowing us to handle future requests.
                                p.request.items.len = 0;

                                const response = blk: {
                                    const route = router.get_route_from_host(request.host);
                                    if (route) |r| {
                                        const context: Context = Context.init(p.arena.allocator(), request.host);
                                        const handler = r.get_handler(request.method);

                                        if (handler) |func| {
                                            const resp = func(request, context);
                                            break :blk try resp.respond_into_buffer(p.buffer);
                                        } else {
                                            const resp = Response.init(.@"Method Not Allowed", Mime.HTML, "");
                                            break :blk try resp.respond_into_buffer(p.buffer);
                                        }
                                    }

                                    // Default Response.
                                    var resp = Response.init(.@"Not Found", Mime.HTML, "");
                                    break :blk try resp.respond_into_buffer(p.buffer);
                                };

                                p.job = .Write;
                                _ = try uring.send(cqe.user_data, p.socket, response, 0);
                            } else {
                                _ = try uring.recv(cqe.user_data, p.socket, .{ .buffer = p.buffer }, 0);
                            }
                        } else {
                            _ = p.arena.reset(.{ .retain_with_limit = config.size_context_arena_retain });
                            provision_pool.release(p.index);
                        }
                    },

                    .Write => {
                        const write_count = cqe.res;
                        _ = write_count;
                        p.job = .Read;
                        _ = try uring.recv(cqe.user_data, p.socket, .{ .buffer = p.buffer }, 0);
                    },

                    .Close => {},
                }
            }

            if (!provision_pool.full) {
                _ = try uring.accept(@as(u64, @intFromPtr(&first_provision)), server_socket, null, null, 0);
            }

            _ = try uring.submit_and_wait(1);
            assert(uring.cq_ready() >= 1);
        }

        unreachable;
    }

    pub fn listen(self: *Server) !void {
        assert(self.socket != null);
        const server_socket = self.socket.?;

        // Lock the Router.
        self.router.locked = true;

        log.info("server listening...", .{});
        log.info("threading mode: {s}", .{@tagName(self.config.threading)});
        try std.posix.listen(server_socket, self.config.size_backlog_kernel);

        const base_flags = std.os.linux.IORING_SETUP_COOP_TASKRUN | std.os.linux.IORING_SETUP_SINGLE_ISSUER;

        // Create our Ring.
        var uring = try std.os.linux.IoUring.init(
            self.config.size_connections_max,
            base_flags,
        );
        const fd = uring.fd;

        switch (self.config.threading) {
            .single_threaded => try run(self.config, self.router, server_socket, &uring),
            .multi_threaded => |count| {
                const allocator = self.config.allocator;
                var threads = std.ArrayList(std.Thread).init(allocator);

                const thread_count = blk: {
                    switch (count) {
                        .auto => break :blk try std.Thread.getCpuCount(),
                        .count => |inner| break :blk inner,
                    }
                };

                log.info("spawning {d} threads", .{thread_count});

                for (0..thread_count) |i| {
                    try threads.append(try std.Thread.spawn(.{ .allocator = allocator }, struct {
                        fn handler_fn(
                            config: ServerConfig,
                            router: Router,
                            s_socket: std.posix.socket_t,
                            uring_fd: std.posix.fd_t,
                            thread_id: usize,
                        ) void {
                            var flags: u32 = base_flags;
                            flags |= std.os.linux.IORING_SETUP_ATTACH_WQ;

                            var params = std.mem.zeroInit(std.os.linux.io_uring_params, .{
                                .wq_fd = @as(u32, @intCast(uring_fd)),
                                .flags = flags,
                            });

                            var thread_uring = std.os.linux.IoUring.init_params(config.size_connections_max, &params) catch unreachable;

                            run(config, router, s_socket, &thread_uring) catch {
                                log.err("thread #{d} failed due to unrecoverable error!", .{thread_id});
                            };
                        }
                    }.handler_fn, .{ self.config, self.router, server_socket, fd, i }));
                }

                try run(self.config, self.router, server_socket, &uring);
            },
        }
    }
};
