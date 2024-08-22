const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.@"zzz/server");

const Async = @import("../async/lib.zig").Async;

const Job = @import("../core/lib.zig").Job;
const Pool = @import("../core/lib.zig").Pool;
const Pseudoslice = @import("../core/lib.zig").Pseudoslice;

const HTTPError = @import("lib.zig").HTTPError;
const Request = @import("lib.zig").Request;
const Response = @import("lib.zig").Response;
const Mime = @import("lib.zig").Mime;
const Context = @import("lib.zig").Context;
const Router = @import("lib.zig").Router;

const Capture = @import("routing_trie.zig").Capture;
const Provision = @import("provision.zig").Provision;

const ServerThreadCount = union(enum) {
    auto,
    count: u32,
};

const ServerThreading = union(enum) {
    single_threaded,
    multi_threaded: ServerThreadCount,
};

const IpVersion = enum {
    auto,
    ipv4,
    ipv6,
};

pub const ServerConfig = struct {
    /// The allocator that server will use.
    allocator: std.mem.Allocator,
    /// Threading Model to use.
    ///
    /// Default: .single_threaded
    threading: ServerThreading = .single_threaded,
    /// IP Version to use.
    ///
    /// Default: .auto
    ip_version: IpVersion = .auto,
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
    /// Maximum number of headers
    ///
    /// Default: 32
    num_header_max: u8 = 32,
    /// Maximum number of Captures in a Route URL.
    ///
    /// Default: 8
    num_captures_max: u32 = 8,
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

    pub fn bind(self: *Server, host: []const u8, port: u16) !void {
        assert(host.len > 0);
        assert(port > 0);
        defer assert(self.socket != null);

        const addr = blk: {
            log.info("resolving with ip version: {s}", .{@tagName(self.config.ip_version)});
            switch (self.config.ip_version) {
                .auto => {
                    log.info("binding zzz server on {s}:{d}", .{ host, port });
                    break :blk try std.net.Address.resolveIp(host, port);
                },
                .ipv4 => {
                    log.info("binding zzz server on {s}:{d} | forcing ipv4", .{ host, port });
                    break :blk try std.net.Address.parseIp4(host, port);
                },
                .ipv6 => {
                    log.info("binding zzz server on {s}:{d} | forcing ipv6", .{ host, port });
                    break :blk try std.net.Address.resolveIp6(host, port);
                },
            }
        };

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

    /// Uses the current p.response to generate and queue up the sending
    /// of a response. This is used when we already know what we want to send.
    ///
    /// See: `route_and_respond`
    fn raw_respond(p: *Provision, backend: *Async, config: ServerConfig) !void {
        const body = p.response.body orelse "";
        const header_buffer = try p.response.headers_into_buffer(p.buffer, @intCast(body.len));
        var pseudo = Pseudoslice.init(header_buffer, body, p.buffer);
        p.job = .{ .Send = .{ .slice = pseudo, .count = 0 } };
        try backend.queue_send(p, p.socket, pseudo.get(0, config.size_socket_buffer));
    }

    fn route_and_respond(p: *Provision, backend: *Async, router: Router, config: ServerConfig) !void {
        route: {
            const captured = router.get_route_from_host(p.request.uri, p.captures);
            if (captured) |c| {
                const handler = c.route.get_handler(p.request.method);

                if (handler) |func| {
                    const context: Context = Context.init(
                        p.arena.allocator(),
                        p.request.uri,
                        c.captures,
                    );

                    func(p.request, &p.response, context);
                    break :route;
                } else {
                    // If we match the route but not the method.
                    p.response.set(.{
                        .status = .@"Method Not Allowed",
                        .mime = Mime.HTML,
                        .body = "405 Method Not Allowed",
                    });

                    // We also need to add to Allow header.
                    // This uses the connection's arena to allocate 64 bytes.
                    const allowed = c.route.get_allowed(p.arena.allocator()) catch {
                        p.response.set(.{
                            .status = .@"Internal Server Error",
                            .mime = Mime.HTML,
                            .body = "",
                        });

                        break :route;
                    };

                    p.response.headers.add("Allow", allowed) catch {
                        p.response.set(.{
                            .status = .@"Internal Server Error",
                            .mime = Mime.HTML,
                            .body = "",
                        });

                        break :route;
                    };

                    break :route;
                }
            }

            // Didn't match any route.
            p.response.set(.{
                .status = .@"Not Found",
                .mime = Mime.HTML,
                .body = "404 Not Found",
            });
            break :route;
        }

        if (p.response.status == .Kill) {
            return error.Kill;
        }

        try raw_respond(p, backend, config);
    }

    fn clean_connection(provision: *Provision, provision_pool: *Pool(Provision), config: ServerConfig) void {
        std.posix.close(provision.socket);
        _ = provision.arena.reset(.{ .retain_with_limit = config.size_context_arena_retain });
        provision.response.clear();
        provision.request_buffer.clearAndFree();
        provision_pool.release(provision.index);
    }

    /// This function assumes that the socket is set up and
    /// is already listening.
    fn run(config: ServerConfig, router: Router, server_socket: std.posix.socket_t, backend: *Async) !void {
        const allocator = config.allocator;

        var provision_pool = try Pool(Provision).init(allocator, config.size_connections_max, struct {
            fn init_hook(provisions: []Provision, ctx: anytype) void {
                for (provisions) |*provision| {
                    provision.socket = undefined;
                    // Create Buffer
                    provision.buffer = ctx.allocator.alloc(u8, ctx.size_socket_buffer) catch {
                        panic("attempting to statically allocate more memory than available. (Socket Buffer)", .{});
                    };
                    // Create Captures
                    provision.captures = ctx.allocator.alloc(Capture, ctx.num_captures_max) catch {
                        panic("attempting to statically allocate more memory than available. (Captures)", .{});
                    };
                    // Create Request ArrayList
                    provision.request_buffer = std.ArrayList(u8).init(ctx.allocator);
                    // Create Request
                    provision.request = Request.init(ctx.allocator, .{
                        .size_request_max = ctx.size_request_max,
                        .num_header_max = ctx.num_header_max,
                    }) catch {
                        panic("attempting to statically allocate more memory than available. (Request)", .{});
                    };
                    // Create Response
                    provision.response = Response.init(ctx.allocator, .{
                        .num_headers_max = ctx.num_header_max,
                    }) catch {
                        panic("attempting to statically allocate more memory than available. (Response)", .{});
                    };
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
                    provision.request.deinit();
                    provision.response.deinit();
                    provision.arena.deinit();
                }
            }
        }.deinit_hook, config);

        // Create and send the first Job.
        var first_provision = Provision{
            .job = .Accept,
            .index = undefined,
            .socket = undefined,
            .captures = undefined,
            .request = undefined,
            .request_buffer = undefined,
            .response = undefined,
            .arena = undefined,
            .buffer = undefined,
        };

        var accepted = false;
        _ = try backend.queue_accept(&first_provision, server_socket);
        try backend.submit();

        while (true) {
            const completions = try backend.reap();
            const completions_count = completions.len;
            assert(completions_count > 0);

            reap_loop: for (completions[0..completions_count]) |completion| {
                const p: *Provision = @ptrCast(@alignCast(completion.context));

                switch (p.job) {
                    .Accept => {
                        accepted = true;
                        const socket: std.posix.socket_t = completion.result;

                        // Borrow a provision from the pool otherwise close the socket.
                        const provision = provision_pool.borrow(@intCast(completion.result)) catch {
                            std.posix.close(socket);
                            continue :reap_loop;
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
                        provision.item.job = .{ .Recv = .{ .kind = .Header, .count = 0 } };
                        _ = try backend.queue_recv(provision.item, socket, provision.item.buffer);
                    },

                    .Recv => |*read_inner| {
                        const kind = read_inner.kind;
                        const read_count = completion.result;

                        // If the socket is closed.
                        if (read_count <= 0) {
                            clean_connection(p, &provision_pool, config);
                            continue :reap_loop;
                        }

                        read_inner.count += @intCast(read_count);

                        switch (kind) {
                            .Header => {
                                try p.request_buffer.appendSlice(p.buffer[0..@as(usize, @intCast(read_count))]);

                                const header_ends = std.mem.lastIndexOf(u8, p.request_buffer.items, "\r\n\r\n");
                                const too_long = p.request_buffer.items.len >= config.size_request_max;

                                // Basically, this means we haven't finished processing the header.
                                if (header_ends == null and !too_long) {
                                    _ = try backend.queue_recv(completion.context, p.socket, p.buffer);
                                    continue :reap_loop;
                                }

                                // The +4 is to account for the slice we match.
                                const header_end: u32 = @intCast(header_ends.? + 4);
                                p.request.parse_headers(p.request_buffer.items[0..header_end]) catch |e| {
                                    switch (e) {
                                        HTTPError.ContentTooLarge => {
                                            p.response.set(.{
                                                .status = .@"Content Too Large",
                                                .mime = Mime.HTML,
                                                .body = "Request was too large",
                                            });
                                        },
                                        HTTPError.TooManyHeaders => {
                                            p.response.set(.{
                                                .status = .@"Request Header Fields Too Large",
                                                .mime = Mime.HTML,
                                                .body = "Too Many Headers",
                                            });
                                        },
                                        HTTPError.MalformedRequest => {
                                            p.response.set(.{
                                                .status = .@"Bad Request",
                                                .mime = Mime.HTML,
                                                .body = "Malformed Request",
                                            });
                                        },
                                        HTTPError.URITooLong => {
                                            p.response.set(.{
                                                .status = .@"URI Too Long",
                                                .mime = Mime.HTML,
                                                .body = "URI Too Long",
                                            });
                                        },
                                        HTTPError.InvalidMethod => {
                                            p.response.set(.{
                                                .status = .@"Not Implemented",
                                                .mime = Mime.HTML,
                                                .body = "Not Implemented",
                                            });
                                        },
                                        HTTPError.HTTPVersionNotSupported => {
                                            p.response.set(.{
                                                .status = .@"HTTP Version Not Supported",
                                                .mime = Mime.HTML,
                                                .body = "HTTP Version Not Supported",
                                            });
                                        },
                                    }

                                    raw_respond(p, backend, config) catch return;
                                    continue :reap_loop;
                                };

                                if (!p.request.expect_body()) {
                                    route_and_respond(p, backend, router, config) catch return;
                                    continue :reap_loop;
                                }

                                // Everything after here is a Request that is expecting a body.
                                const content_length = blk: {
                                    const length_string = p.request.headers.get("Content-Length") orelse {
                                        break :blk 0;
                                    };

                                    break :blk std.fmt.parseInt(u32, length_string, 10) catch {
                                        p.response.set(.{
                                            .status = .@"Bad Request",
                                            .mime = Mime.HTML,
                                            .body = "",
                                        });
                                        raw_respond(p, backend, config) catch return;
                                        continue :reap_loop;
                                    };
                                };

                                if (header_end < p.request_buffer.items.len) {
                                    const difference = p.request_buffer.items.len - header_end;
                                    if (difference == content_length) {
                                        // Whole Body
                                        log.debug("Got whole body with header", .{});
                                        const body_end = header_end + difference;
                                        p.request.set_body(p.request_buffer.items[header_end..body_end]);
                                        route_and_respond(p, backend, router, config) catch return;
                                        continue :reap_loop;
                                    } else {
                                        // Partial Body
                                        log.debug("Got partial body with header", .{});
                                        read_inner.kind = .{ .Body = header_end };
                                        try backend.queue_recv(completion.context, p.socket, p.buffer);
                                        continue :reap_loop;
                                    }
                                } else if (header_end == p.request_buffer.items.len) {
                                    // Body of length 0 probably or only got header.
                                    if (content_length == 0) {
                                        // Body of Length 0.
                                        p.request.set_body("");
                                        route_and_respond(p, backend, router, config) catch return;
                                        continue :reap_loop;
                                    } else {
                                        // Got only header.
                                        log.debug("Got no body, all header", .{});
                                        read_inner.kind = .{ .Body = header_end };
                                        try backend.queue_recv(completion.context, p.socket, p.buffer);
                                        continue :reap_loop;
                                    }
                                } else unreachable;
                            },

                            .Body => |header_end| {
                                // We should ONLY be here if we expect there to be a body.
                                assert(p.request.expect_body());
                                log.debug("Body Matching Fired!", .{});

                                const content_length = blk: {
                                    const length_string = p.request.headers.get("Content-Length") orelse {
                                        p.response.set(.{
                                            .status = .@"Length Required",
                                            .mime = Mime.HTML,
                                            .body = "",
                                        });
                                        raw_respond(p, backend, config) catch return;
                                        continue :reap_loop;
                                    };

                                    break :blk std.fmt.parseInt(u32, length_string, 10) catch {
                                        p.response.set(.{
                                            .status = .@"Bad Request",
                                            .mime = Mime.HTML,
                                            .body = "",
                                        });
                                        raw_respond(p, backend, config) catch return;
                                        continue :reap_loop;
                                    };
                                };

                                // If this body will be too long, abort early.
                                if (header_end + content_length > config.size_request_max) {
                                    p.response.set(.{
                                        .status = .@"Content Too Large",
                                        .mime = Mime.HTML,
                                        .body = "",
                                    });
                                    raw_respond(p, backend, config) catch return;
                                    continue :reap_loop;
                                }

                                if (read_inner.count >= content_length) {
                                    const end = header_end + content_length;
                                    p.request.set_body(p.request_buffer.items[header_end..end]);
                                    route_and_respond(p, backend, router, config) catch return;
                                } else {
                                    try backend.queue_recv(completion.context, p.socket, p.buffer);
                                }
                            },
                        }
                    },

                    .Send => |*inner| {
                        const write_count = completion.result;

                        if (write_count <= 0) {
                            clean_connection(p, &provision_pool, config);
                            continue :reap_loop;
                        }

                        inner.count += @intCast(write_count);

                        if (inner.count >= inner.slice.len) {
                            p.response.clear();
                            p.request_buffer.clearRetainingCapacity();

                            p.job = .{ .Recv = .{ .kind = .Header, .count = 0 } };
                            try backend.queue_recv(completion.context, p.socket, p.buffer);
                        } else {
                            try backend.queue_send(
                                completion.context,
                                p.socket,
                                inner.slice.get(inner.count, inner.count + config.size_socket_buffer),
                            );
                        }
                    },

                    .Close => {
                        log.debug("closed a fd", .{});
                    },

                    else => @panic("Not implemented yet!"),
                }
            }

            if (!provision_pool.full and accepted) {
                try backend.queue_accept(&first_provision, server_socket);
                accepted = false;
            }

            try backend.submit();
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

        // Choose a backend here to use with the socket.
        const AsyncIoUring = @import("../async/io_uring.zig").AsyncIoUring;
        const base_flags = std.os.linux.IORING_SETUP_COOP_TASKRUN | std.os.linux.IORING_SETUP_SINGLE_ISSUER;

        // Create our Ring.
        var uring = try std.os.linux.IoUring.init(
            self.config.size_connections_max,
            base_flags,
        );

        var uring_backend = try AsyncIoUring.init(&uring);
        var backend = uring_backend.to_async();

        const fd = uring.fd;
        assert(fd >= 0);

        switch (self.config.threading) {
            .single_threaded => run(self.config, self.router, server_socket, &backend) catch {
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

                            var thread_uring_backend = try AsyncIoUring.init(&thread_uring);
                            var thread_backend = thread_uring_backend.to_async();

                            run(config, router, s_socket, &thread_backend) catch {
                                log.err("thread #{d} failed due to unrecoverable error!", .{thread_id});
                            };
                        }
                    }.handler_fn, .{ self.config, self.router, server_socket, fd, i }));
                }

                run(self.config, self.router, server_socket, &backend) catch {
                    log.err("root thread failed due to unrecoverable error!", .{});
                };

                for (threads.items) |thread| {
                    thread.join();
                }
            },
        }
    }
};
