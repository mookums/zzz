const std = @import("std");
const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.@"zzz/server");

const Job = @import("../core/lib.zig").Job;
const Pool = @import("../core/lib.zig").Pool;
const Pseudoslice = @import("../core/lib.zig").Pseudoslice;

const HTTPError = @import("lib.zig").HTTPError;

const Capture = @import("routing_trie.zig").Capture;
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
    ///
    /// Default: 2MB.
    size_request_max: u32 = 1024 * 1024 * 2,
    /// Size of the buffer (in bytes) used for
    /// interacting with the Socket.
    ///
    /// Default: 4 KB.
    size_socket_buffer: u32 = 1024 * 4,
    /// Maximum number of headers per Response.
    ///
    /// Default: 8
    response_headers_max: u8 = 8,
    /// Maximum number of Captures in a Route URL.
    ///
    /// Default: 8
    size_captures_max: u32 = 8,
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

    fn respond(p: *Provision, uring: *std.os.linux.IoUring, router: Router, config: ServerConfig) !void {
        _ = config;
        p.response = blk: {
            const captured = router.get_route_from_host(p.request.host, p.captures);
            if (captured) |c| {
                const handler = c.route.get_handler(p.request.method);

                if (handler) |func| {
                    const context: Context = Context.init(
                        p.arena.allocator(),
                        p.request.host,
                        c.captures,
                    );

                    break :blk func(p.request, context);
                } else {
                    // If we match the route but not the method.
                    break :blk Response.init(
                        .@"Method Not Allowed",
                        Mime.HTML,
                        "405 Method Not Allowed",
                    );
                }
            }

            // Didn't match any route.
            break :blk Response.init(
                .@"Not Found",
                Mime.HTML,
                "404 Not Found",
            );
        };

        if (p.response.status == .Kill) {
            return error.Kill;
        }

        const response_buffer = p.response.response_into_buffer(p.buffer) catch blk: {
            p.response = Response.init(
                .@"Internal Server Error",
                Mime.HTML,
                "The response being returned is too large.",
            );

            break :blk try p.response.response_into_buffer(p.buffer);
        };

        p.header_end = response_buffer.len;
        p.job = .Write;
        _ = uring.send(@as(u64, @intFromPtr(p)), p.socket, response_buffer, 0) catch unreachable;
    }

    /// This function assumes that the socket is set up and
    /// is already listening.
    fn run(config: ServerConfig, router: Router, server_socket: std.posix.socket_t, uring: *std.os.linux.IoUring) !void {
        const allocator = config.allocator;
        defer uring.deinit();

        // Create a buffer of Completion Queue Events to copy into.
        const cqes = try allocator.alloc(std.os.linux.io_uring_cqe, config.size_connections_max);
        defer allocator.free(cqes);

        var provision_pool = try Pool(Provision).init(allocator, config.size_connections_max, struct {
            fn init_hook(provisions: []Provision, ctx: anytype) void {
                for (provisions) |*provision| {
                    provision.socket = undefined;
                    // Create Buffer
                    provision.buffer = ctx.allocator.alloc(u8, ctx.size_socket_buffer) catch {
                        panic("attemping to statically allocate more memory than available.", .{});
                    };
                    // Create Captures
                    provision.captures = ctx.allocator.alloc(Capture, ctx.size_captures_max) catch {
                        panic("attemping to statically allocate more memory than available.", .{});
                    };
                    // Create Request ArrayList
                    provision.request_buffer = std.ArrayList(u8).initCapacity(ctx.allocator, ctx.size_socket_buffer) catch {
                        panic("attemping to statically allocate more memory than available.", .{});
                    };

                    // These all need to get created during the lifetime of a connection.
                    // They should not be created here, this way we can catch any weird
                    // undefined behavior at test and run time.
                    provision.request = undefined;
                    provision.response = undefined;
                    provision.pseudo = undefined;

                    provision.header_end = 0;
                    provision.count = 0;
                    // Create the Context Arena
                    provision.arena = std.heap.ArenaAllocator.init(ctx.allocator);
                }
            }
        }.init_hook, config);

        defer provision_pool.deinit(struct {
            fn deinit_hook(provisions: []Provision, ctx: anytype) void {
                for (provisions) |*provision| {
                    ctx.allocator.free(provision.buffer);
                    ctx.allocator.free(provision.captures);
                    provision.request_buffer.deinit();
                    provision.arena.deinit();
                }
            }
        }.deinit_hook, config);

        // Create and send the first Job.
        const first_provision = Provision{
            .job = .Accept,
            .index = undefined,
            .socket = undefined,
            .captures = undefined,
            .request = undefined,
            .request_buffer = undefined,
            .response = undefined,
            .pseudo = undefined,
            .arena = undefined,
            .buffer = undefined,
            .header_end = 0,
            .count = 0,
        };

        var accepted = false;
        _ = try uring.accept(@as(u64, @intFromPtr(&first_provision)), server_socket, null, null, 0);

        while (true) {
            const cqe_count = try uring.copy_cqes(cqes, 0);

            cqe_loop: for (0..cqe_count) |i| {
                const cqe = cqes[i];
                const p: *Provision = @ptrFromInt(cqe.user_data);

                switch (p.job) {
                    .Accept => {
                        accepted = true;
                        const socket: std.posix.socket_t = cqe.res;

                        // Borrow a provision from the pool otherwise close the socket.
                        const provision = provision_pool.borrow(@intCast(cqe.res)) catch {
                            std.posix.close(socket);
                            continue :cqe_loop;
                        };

                        // Disable Nagle's.
                        try std.posix.setsockopt(
                            socket,
                            std.posix.IPPROTO.TCP,
                            std.posix.TCP.NODELAY,
                            &std.mem.toBytes(@as(c_int, 1)),
                        );

                        // Store the index of this item.
                        provision.item.index = provision.index;
                        provision.item.socket = socket;
                        provision.item.job = .{ .Read = .Header };

                        const read_buffer = .{ .buffer = provision.item.buffer };
                        _ = try uring.recv(@as(u64, @intFromPtr(provision.item)), socket, read_buffer, 0);
                    },

                    .Read => |kind| {
                        const read_count = cqe.res;

                        // If the socket is closed.
                        if (read_count <= 0) {
                            _ = p.arena.reset(.{ .retain_with_limit = config.size_context_arena_retain });
                            p.request_buffer.clearAndFree();
                            provision_pool.release(p.index);
                            continue :cqe_loop;
                        }

                        switch (kind) {
                            .Header => {
                                try p.request_buffer.appendSlice(p.buffer[0..@as(usize, @intCast(read_count))]);

                                const header_ends = std.mem.lastIndexOf(u8, p.request_buffer.items, "\r\n\r\n");
                                const too_long = p.request_buffer.items.len >= config.size_request_max;

                                // Basically, this means we haven't finished processing the header.
                                if (header_ends == null and !too_long) {
                                    _ = try uring.recv(cqe.user_data, p.socket, .{ .buffer = p.buffer }, 0);
                                    continue :cqe_loop;
                                }

                                // The +4 is to account for the slice we match.
                                p.header_end = header_ends.? + 4;
                                p.request.parse_headers(p.request_buffer.items[0..p.header_end]) catch |e| {
                                    p.response = switch (e) {
                                        HTTPError.TooManyHeaders,
                                        HTTPError.ContentTooLarge,
                                        => Response.init(
                                            .@"Request Headers Fields Too Large",
                                            Mime.HTML,
                                            "Too Many Headers",
                                        ),
                                        HTTPError.MalformedRequest => Response.init(
                                            .@"Bad Request",
                                            Mime.HTML,
                                            "Malformed Request",
                                        ),
                                    };

                                    p.job = .Write;
                                    const response_buffer = try p.response.response_into_buffer(p.buffer);
                                    _ = try uring.send(cqe.user_data, p.socket, response_buffer, 0);
                                    continue :cqe_loop;
                                };

                                if (!p.request.expect_body()) {
                                    respond(p, uring, router, config) catch return;
                                    continue :cqe_loop;
                                }

                                // Everything after here is a Request that is expecting a body.
                                const content_length = blk: {
                                    // Basically, we are searching for Content-Length.
                                    // If we don't have it, we assume the length is 0.
                                    for (p.request.headers[0..p.request.headers_idx]) |header| {
                                        if (std.mem.eql(u8, "Content-Length", header.key)) {
                                            break :blk std.fmt.parseInt(u32, header.value, 10) catch {
                                                p.job = .Write;
                                                p.response = Response.init(.@"Bad Request", Mime.HTML, "");
                                                const response_buffer = try p.response.response_into_buffer(p.buffer);
                                                _ = try uring.send(cqe.user_data, p.socket, response_buffer, 0);
                                                continue :cqe_loop;
                                            };
                                        }
                                    }

                                    break :blk 0;
                                };

                                if (p.header_end < p.request_buffer.items.len) {
                                    const difference = p.request_buffer.items.len - p.header_end;
                                    if (difference == content_length) {
                                        // Whole Body
                                        log.debug("Got whole body with header", .{});
                                        p.request.set_body(p.request_buffer.items[p.header_end .. p.header_end + difference]);
                                        respond(p, uring, router, config) catch return;
                                        continue :cqe_loop;
                                    } else {
                                        // Partial Body
                                        log.debug("Got partial body with header", .{});
                                        p.job = .{ .Read = .Body };
                                        _ = try uring.recv(cqe.user_data, p.socket, .{ .buffer = p.buffer }, 0);
                                        continue :cqe_loop;
                                    }
                                } else if (p.header_end == p.request_buffer.items.len) {
                                    // Body of length 0 probably or only got header.
                                    if (content_length == 0) {
                                        // Body of Length 0.
                                        p.request.set_body("");
                                        respond(p, uring, router, config) catch return;
                                        continue :cqe_loop;
                                    } else {
                                        // Got only header.
                                        log.debug("Got no body, all header", .{});
                                        p.job = .{ .Read = .Body };
                                        _ = try uring.recv(cqe.user_data, p.socket, .{ .buffer = p.buffer }, 0);
                                        continue :cqe_loop;
                                    }
                                } else unreachable;
                            },

                            .Body => {
                                // We should ONLY be here if we expect there to be a body.
                                assert(p.request.expect_body());
                                log.debug("Body Matching Fired!", .{});

                                const content_length = blk: {
                                    for (p.request.headers[0..p.request.headers_idx]) |header| {
                                        if (std.mem.eql(u8, header.key, "Content-Length")) {
                                            break :blk std.fmt.parseInt(u32, header.value, 10) catch {
                                                p.response = Response.init(.@"Bad Request", Mime.HTML, "");
                                                const response_buffer = try p.response.response_into_buffer(p.buffer);
                                                p.job = .Write;
                                                _ = try uring.send(cqe.user_data, p.socket, response_buffer, 0);
                                                continue :cqe_loop;
                                            };
                                        }
                                    }

                                    // Return a missing header response.
                                    const response = Response.init(.@"Length Required", Mime.HTML, "");
                                    const response_buffer = try response.response_into_buffer(p.buffer);
                                    p.job = .Write;
                                    _ = try uring.send(cqe.user_data, p.socket, response_buffer, 0);
                                    continue :cqe_loop;
                                };

                                // If this body will be too long, abort early.
                                if (p.header_end + content_length > config.size_request_max) {
                                    p.response = Response.init(.@"Content Too Large", Mime.HTML, "");
                                    const response_buffer = try p.response.response_into_buffer(p.buffer);
                                    p.job = .Write;
                                    _ = try uring.send(cqe.user_data, p.socket, response_buffer, 0);
                                    continue :cqe_loop;
                                }

                                if (p.count >= content_length) {
                                    p.request.set_body(p.request_buffer.items[p.header_end..(p.header_end + content_length)]);
                                    respond(p, uring, router, config) catch return;
                                } else {
                                    _ = try uring.recv(cqe.user_data, p.socket, .{ .buffer = p.buffer }, 0);
                                }
                            },
                        }
                    },

                    .Write => {
                        // When we are sending the write, we need to think of a couple of conditions.
                        // We basically want to coalese the header and body into a pseudo-buffer.
                        // We then want to send out this pseudo-buffer, tracking when it doesn't fully send.
                        const write_count = cqe.res;
                        // We need to create the Pseudoslice at the START of the write set and keep it that way.
                        if (write_count <= 0) {
                            // Try resetting the arena after writing each request.
                            _ = p.arena.reset(.{ .retain_with_limit = config.size_context_arena_retain });
                            p.request_buffer.clearAndFree();
                            provision_pool.release(p.index);
                            continue :cqe_loop;
                        }

                        p.request_buffer.shrinkAndFree(@min(p.request_buffer.items.len, 256));
                        p.request_buffer.clearRetainingCapacity();

                        p.job = .{ .Read = .Header };
                        _ = try uring.recv(cqe.user_data, p.socket, .{ .buffer = p.buffer }, 0);
                    },

                    .Close => {},
                }
            }

            if (!provision_pool.full and accepted) {
                _ = try uring.accept(@as(u64, @intFromPtr(&first_provision)), server_socket, null, null, 0);
                accepted = false;
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
        assert(fd >= 0);

        switch (self.config.threading) {
            .single_threaded => run(self.config, self.router, server_socket, &uring) catch {
                log.err("failed due to unrecoverable error!", .{});
                return;
            },
            .multi_threaded => |count| {
                const allocator = self.config.allocator;
                var threads = std.ArrayList(std.Thread).init(allocator);
                defer threads.deinit();

                const thread_count = blk: {
                    switch (count) {
                        .auto => break :blk @max(try std.Thread.getCpuCount() / 2 - 1, 1),
                        .count => |inner| break :blk inner,
                    }
                };

                log.info("spawning {d} thread[s] + 1 root thread", .{thread_count});

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

                            var thread_uring = std.os.linux.IoUring.init_params(
                                config.size_connections_max,
                                &params,
                            ) catch {
                                log.err("thread #{d} unable to start! (uring initalization)", .{thread_id});
                                return;
                            };

                            run(config, router, s_socket, &thread_uring) catch {
                                log.err("thread #{d} failed due to unrecoverable error!", .{thread_id});
                            };
                        }
                    }.handler_fn, .{ self.config, self.router, server_socket, fd, i }));
                }

                run(self.config, self.router, server_socket, &uring) catch {
                    log.err("root thread failed due to unrecoverable error!", .{});
                };

                for (threads.items) |thread| {
                    thread.join();
                }
            },
        }
    }
};
