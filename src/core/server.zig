const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/server");

const Async = @import("../async/lib.zig").Async;
const AutoAsyncType = @import("../async/lib.zig").AutoAsyncType;
const AsyncType = @import("../async/lib.zig").AsyncType;
const AsyncIoUring = @import("../async/io_uring.zig").AsyncIoUring;

const Pseudoslice = @import("pseudoslice.zig").Pseudoslice;
const Pool = @import("pool.zig").Pool;
const Socket = @import("socket.zig").Socket;
const ZProvision = @import("zprovision.zig").ZProvision;

const TLSContext = @import("../tls/lib.zig").TLSContext;
const TLS = @import("../tls/lib.zig").TLS;

pub const RecvStatus = union(enum) {
    Kill,
    Recv,
    Send: Pseudoslice,
};

const ServerTLS = union(enum) {
    plain,
    tls: struct { cert: []const u8, key: []const u8 },
};

const ServerThreadCount = union(enum) {
    auto,
    count: u32,
};

const ServerThreading = union(enum) {
    single_threaded,
    multi_threaded: ServerThreadCount,
};

/// These are various general configuration
/// options that are important for the actual framework.
///
/// This includes various different options and limits
/// for interacting with the underlying network.
pub const zzzConfig = struct {
    /// The allocator that server will use.
    allocator: std.mem.Allocator,
    /// Threading Model to use.
    ///
    /// Default: .single_threaded
    threading: ServerThreading = .single_threaded,
    /// Encryption Model to use.
    ///
    /// Default: .plain (plaintext)
    encryption: ServerTLS = .plain,
    /// Kernel Backlog Value.
    size_backlog: u31 = 512,
    /// Number of Maximum Concurrnet Connections.
    ///
    /// This is applied PER thread if using multi-threading.
    /// zzz will drop/close any connections greater
    /// than this.
    ///
    /// You want to tune this to your expected number
    /// of maximum connections.
    ///
    /// Default: 1024
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
    /// Default: 1KB
    size_connection_arena_retain: u32 = 1024,
    /// Size of the buffer (in bytes) used for
    /// interacting with the Socket.
    ///
    /// Default: 4 KB.
    size_socket_buffer: u32 = 1024 * 4,
    /// Maximum size (in bytes) of the Recv buffer.
    /// This is mainly a concern when you are reading in
    /// large requests before responding.
    ///
    /// Default: 2MB.
    size_recv_buffer_max: u32 = 1024 * 1024 * 2,
};

/// This is a basic Server building block of the zzz framework. To build a server,
/// you must provide an Async Backend, your Provision type, your provision init and deinit
/// functions and an allocator.
///
/// You then must provide the hooks (aka the actual functions) that handle your communication.
pub fn Server(
    comptime ProtocolData: type,
    comptime ProtocolConfig: type,
    /// This is called after the Accept.
    comptime accept_fn: ?*const fn (
        provision: *ZProvision(ProtocolData),
        p_config: ProtocolConfig,
        z_config: zzzConfig,
        backend: *Async,
    ) void,
    /// This is called after the Recv.
    comptime recv_fn: *const fn (
        provision: *ZProvision(ProtocolData),
        p_config: ProtocolConfig,
        z_config: zzzConfig,
        backend: *Async,
        recv_buffer: []const u8,
    ) RecvStatus,
) type {
    return struct {
        const Provision = ZProvision(ProtocolData);
        const Self = @This();
        allocator: std.mem.Allocator,
        config: zzzConfig,
        socket: ?Socket = null,
        tls_ctx: ?TLSContext = null,
        backend_type: AsyncType,

        pub fn init(config: zzzConfig, async_type: ?AsyncType) Self {
            const backend_type = async_type orelse AutoAsyncType;

            const tls_ctx = switch (config.encryption) {
                .tls => |inner| TLSContext.init(.{
                    .allocator = config.allocator,
                    .cert_path = inner.cert,
                    .cert_name = "CERTIFICATE",
                    .key_path = inner.key,
                    .key_name = "EC PRIVATE KEY",
                    .size_tls_buffer_max = config.size_socket_buffer * 2,
                }) catch unreachable,
                .plain => null,
            };

            return Self{
                .allocator = config.allocator,
                .config = config,
                .socket = null,
                .tls_ctx = tls_ctx,
                .backend_type = backend_type,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.socket) |socket| {
                switch (@TypeOf(Socket)) {
                    std.posix.socket_t => std.posix.close(socket),
                    std.os.windows.ws2_32.SOCKET => std.os.windows.closesocket(socket),
                    else => {},
                }
            }

            if (self.tls_ctx) |*tls_ctx| {
                tls_ctx.deinit();
            }
        }

        /// If you are using a custom implementation that does NOT rely
        /// on TCP/IP, you can SKIP calling this method and just set the
        /// socket value yourself.
        ///
        /// This is only allowed on certain targets that do not have TCP/IP
        /// support.
        pub fn bind(self: *Self, host: []const u8, port: u16) !void {
            // This currently only works on POSIX systems.
            // We should fix this.
            assert(host.len > 0);
            assert(port > 0);
            defer assert(self.socket != null);

            const addr = try std.net.Address.resolveIp(host, port);

            const socket: std.posix.socket_t = blk: {
                const socket_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
                break :blk try std.posix.socket(
                    addr.any.family,
                    socket_flags,
                    std.posix.IPPROTO.TCP,
                );
            };

            log.debug("socket | t: {s} v: {any}", .{ @typeName(Socket), socket });

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

            try std.posix.bind(socket, &addr.any, addr.getOsSockLen());
            self.socket = socket;
        }

        fn clean_connection(
            provision: *Provision,
            provision_pool: *Pool(Provision),
            config: zzzConfig,
        ) void {
            defer provision_pool.release(provision.index);

            log.info("{d} - closing connection", .{provision.index});
            _ = provision.arena.reset(.{ .retain_with_limit = config.size_connection_arena_retain });
            if (provision.tls) |*tls| {
                tls.deinit();
                provision.tls = null;
            }
            provision.data.clean();
            std.posix.close(provision.socket);
        }

        fn run(
            z_config: zzzConfig,
            p_config: ProtocolConfig,
            backend: *Async,
            tls_ctx: ?TLSContext,
            server_socket: Socket,
        ) !void {
            // Creating everything we need to run for the foreseeable future.
            var provision_pool = try Pool(Provision).init(
                z_config.allocator,
                z_config.size_connections_max,
                Provision.init_hook,
                z_config,
            );

            for (provision_pool.items) |*provision| {
                provision.data = ProtocolData.init(z_config.allocator, p_config);
            }

            defer {
                for (provision_pool.items) |*provision| {
                    provision.data.deinit(z_config.allocator);

                    if (provision.tls) |*tls| {
                        tls.deinit();
                    }
                }
                provision_pool.deinit(Provision.deinit_hook, z_config);
            }

            // Create and send the first Job.
            var first_provision = Provision{
                .job = .Accept,
                .index = undefined,
                .socket = undefined,
                .buffer = undefined,
                .recv_buffer = undefined,
                .arena = undefined,
                .data = undefined,
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
                            const socket: Socket = completion.result;

                            if (socket < 0) {
                                log.err("socket accept failed", .{});
                                continue :reap_loop;
                            }

                            // Borrow a provision from the pool otherwise close the socket.
                            const borrowed = provision_pool.borrow(@intCast(completion.result)) catch {
                                continue :reap_loop;
                            };

                            // Disable Nagle's.
                            if (Socket == std.posix.socket_t) {
                                try std.posix.setsockopt(
                                    socket,
                                    std.posix.IPPROTO.TCP,
                                    std.posix.TCP.NODELAY,
                                    &std.mem.toBytes(@as(c_int, 1)),
                                );
                            }

                            const provision = borrowed.item;

                            // Store the index of this item.
                            provision.index = borrowed.index;
                            provision.socket = socket;
                            provision.job = .{ .Recv = .{ .count = 0 } };

                            switch (z_config.encryption) {
                                .tls => |_| {
                                    provision.tls = try tls_ctx.?.create(socket);
                                    provision.tls.?.accept() catch |e| {
                                        log.debug("{d} - tls handshake failed={any}", .{ provision.index, e });
                                        clean_connection(provision, &provision_pool, z_config);
                                        continue :reap_loop;
                                    };
                                },
                                .plain => {},
                            }

                            // Call the Accept Hook.
                            if (accept_fn) |func| {
                                @call(.auto, func, .{ provision, p_config, z_config, backend });
                            }

                            _ = try backend.queue_recv(provision, provision.socket, provision.buffer);
                        },

                        .Recv => |*inner| {
                            log.debug("{d} - recv triggered", .{p.index});

                            // If the socket is closed.
                            if (completion.result <= 0) {
                                clean_connection(p, &provision_pool, z_config);
                                continue :reap_loop;
                            }

                            const read_count: u32 = @intCast(completion.result);
                            inner.count += read_count;
                            const pre_recv_buffer = p.buffer[0..read_count];

                            const recv_buffer = switch (z_config.encryption) {
                                .tls => |_| p.tls.?.decrypt(pre_recv_buffer) catch |e| {
                                    log.debug("{d} - Decrypt Failed: {any}", .{ p.index, e });
                                    clean_connection(p, &provision_pool, z_config);
                                    continue :reap_loop;
                                },
                                .plain => pre_recv_buffer,
                            };

                            log.info("{d} - Recv Buffer: {s}", .{ p.index, recv_buffer });

                            var status: RecvStatus = @call(.auto, recv_fn, .{
                                p,
                                p_config,
                                z_config,
                                backend,
                                recv_buffer,
                            });

                            log.debug("{d} - recv fn status: {s}", .{ p.index, @tagName(status) });

                            switch (status) {
                                .Kill => {
                                    return;
                                },
                                .Recv => {
                                    try backend.queue_recv(p, p.socket, p.buffer);
                                },
                                .Send => |*pslice| {
                                    const plain_buffer = pslice.get(0, z_config.size_socket_buffer);

                                    switch (z_config.encryption) {
                                        .tls => |_| {
                                            const encrypted_buffer = p.tls.?.encrypt(plain_buffer) catch {
                                                clean_connection(p, &provision_pool, z_config);
                                                continue :reap_loop;
                                            };

                                            p.job = .{
                                                .Send = .{
                                                    .TLS = .{
                                                        .slice = pslice.*,
                                                        .count = @intCast(plain_buffer.len),
                                                        .encrypted = encrypted_buffer,
                                                        .encrypted_count = 0,
                                                    },
                                                },
                                            };

                                            try backend.queue_send(p, p.socket, encrypted_buffer);
                                        },
                                        .plain => {
                                            p.job = .{
                                                .Send = .{
                                                    .Plain = .{
                                                        .slice = pslice.*,
                                                        .count = 0,
                                                    },
                                                },
                                            };
                                            try backend.queue_send(p, p.socket, plain_buffer);
                                        },
                                    }
                                },
                            }
                        },

                        .Send => |*send_type| {
                            log.debug("{d} - send triggered", .{p.index});
                            const send_count = completion.result;

                            if (send_count <= 0) {
                                clean_connection(p, &provision_pool, z_config);
                                continue :reap_loop;
                            }

                            switch (send_type.*) {
                                .Plain => |*inner| {
                                    // This is for when sending plaintext.
                                    inner.count += @intCast(send_count);

                                    if (inner.count >= inner.slice.len) {
                                        log.debug("{d} - queueing a new recv", .{p.index});
                                        p.recv_buffer.clearRetainingCapacity();
                                        p.job = .{ .Recv = .{ .count = 0 } };
                                        try backend.queue_recv(p, p.socket, p.buffer);
                                    } else {
                                        log.debug(
                                            "{d} - sending next chunk starting at index {d}",
                                            .{ p.index, inner.count },
                                        );

                                        const plain_buffer = inner.slice.get(
                                            inner.count,
                                            inner.count + z_config.size_socket_buffer,
                                        );

                                        log.debug("{d} - chunk ends at: {d}", .{
                                            p.index,
                                            plain_buffer.len + inner.count,
                                        });

                                        try backend.queue_send(p, p.socket, plain_buffer);
                                    }
                                },
                                .TLS => |*inner| {
                                    // This is for when sending encrypted data.
                                    inner.encrypted_count += @intCast(send_count);

                                    if (inner.encrypted_count >= inner.encrypted.len) {
                                        if (inner.count >= inner.slice.len) {
                                            // All done sending.
                                            log.debug("{d} - queueing a new recv", .{p.index});
                                            p.recv_buffer.clearRetainingCapacity();
                                            p.job = .{ .Recv = .{ .count = 0 } };
                                            try backend.queue_recv(p, p.socket, p.buffer);
                                        } else {
                                            // Queue a new chunk up for sending.
                                            log.debug(
                                                "{d} - sending next chunk starting at index {d}",
                                                .{ p.index, inner.count },
                                            );

                                            const inner_slice = inner.slice.get(
                                                inner.count,
                                                inner.count + z_config.size_socket_buffer,
                                            );

                                            inner.count += @intCast(inner_slice.len);

                                            const encrypted = p.tls.?.encrypt(inner_slice) catch {
                                                clean_connection(p, &provision_pool, z_config);
                                                continue :reap_loop;
                                            };

                                            inner.encrypted = encrypted;
                                            inner.encrypted_count = 0;

                                            try backend.queue_send(p, p.socket, inner.encrypted);
                                        }
                                    } else {
                                        log.debug(
                                            "{d} - sending next encrypted chunk starting at index {d}",
                                            .{ p.index, inner.encrypted_count },
                                        );

                                        const remainder = inner.encrypted[inner.encrypted_count..];
                                        try backend.queue_send(p, p.socket, remainder);
                                    }
                                },
                            }
                        },

                        .Close => {},

                        else => @panic("not implemented yet!"),
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

        pub fn listen(self: *Self, protocol_config: ProtocolConfig) !void {
            assert(self.socket != null);
            const server_socket = self.socket.?;

            log.info("server listening...", .{});
            log.info("threading mode: {s}", .{@tagName(self.config.threading)});
            try std.posix.listen(server_socket, self.config.size_backlog);

            var backend = blk: {
                switch (self.backend_type) {
                    .io_uring => {
                        // Initalize IO Uring
                        const base_flags = std.os.linux.IORING_SETUP_COOP_TASKRUN | std.os.linux.IORING_SETUP_SINGLE_ISSUER;

                        const uring = try self.allocator.create(std.os.linux.IoUring);
                        uring.* = try std.os.linux.IoUring.init(
                            self.config.size_connections_max,
                            base_flags,
                        );

                        var io_uring = try AsyncIoUring.init(uring);
                        break :blk io_uring.to_async();
                    },
                    .custom => |inner| break :blk inner,
                }
            };

            defer {
                switch (self.backend_type) {
                    .io_uring => {
                        const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(backend.runner));
                        uring.deinit();
                        self.allocator.destroy(uring);
                    },
                    else => {},
                }
            }

            switch (self.config.threading) {
                .single_threaded => run(self.config, protocol_config, &backend, self.tls_ctx, server_socket) catch |e| {
                    log.err("failed due to unrecoverable error: {any}", .{e});
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
                                p_config: ProtocolConfig,
                                z_config: zzzConfig,
                                backend_type: AsyncType,
                                thread_tls_ctx: ?TLSContext,
                                s_socket: Socket,
                                thread_id: usize,
                            ) void {
                                var thread_backend = blk: {
                                    switch (backend_type) {
                                        .io_uring => {
                                            // Initalize IO Uring
                                            const base_flags = std.os.linux.IORING_SETUP_COOP_TASKRUN | std.os.linux.IORING_SETUP_SINGLE_ISSUER;

                                            const uring = z_config.allocator.create(std.os.linux.IoUring) catch unreachable;
                                            uring.* = std.os.linux.IoUring.init(
                                                z_config.size_connections_max,
                                                base_flags,
                                            ) catch unreachable;

                                            var io_uring = AsyncIoUring.init(uring) catch unreachable;
                                            break :blk io_uring.to_async();
                                        },
                                        .custom => |inner| break :blk inner,
                                    }
                                };

                                defer {
                                    switch (backend_type) {
                                        .io_uring => {
                                            const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(thread_backend.runner));
                                            uring.deinit();
                                            z_config.allocator.destroy(uring);
                                        },
                                        else => {},
                                    }
                                }

                                run(z_config, p_config, &thread_backend, thread_tls_ctx, s_socket) catch |e| {
                                    log.err("thread #{d} failed due to unrecoverable error: {any}", .{ thread_id, e });
                                };
                            }
                        }.handler_fn, .{ protocol_config, self.config, self.backend_type, self.tls_ctx, server_socket, i }));
                    }

                    run(self.config, protocol_config, &backend, self.tls_ctx, server_socket) catch |e| {
                        log.err("root thread failed due to unrecoverable error: {any}", .{e});
                    };

                    for (threads.items) |thread| {
                        thread.join();
                    }
                },
            }
        }
    };
}
