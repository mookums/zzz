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

const TLSFileOptions = @import("../tls/lib.zig").TLSFileOptions;
const TLSContext = @import("../tls/lib.zig").TLSContext;
const TLS = @import("../tls/lib.zig").TLS;

pub const RecvStatus = union(enum) {
    kill,
    recv,
    send: Pseudoslice,
};

/// Security Model to use.
///
/// Default: .plain (plaintext)
pub const Security = union(enum) {
    plain,
    tls: struct {
        cert: TLSFileOptions,
        key: TLSFileOptions,
        cert_name: []const u8 = "CERTIFICATE",
        key_name: []const u8 = "PRIVATE KEY",
    },
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

fn AcceptFn(comptime ProtocolData: type, comptime ProtocolConfig: type) type {
    return *const fn (
        provision: *ZProvision(ProtocolData),
        p_config: ProtocolConfig,
        z_config: zzzConfig,
        backend: *Async,
    ) void;
}

fn RecvFn(comptime ProtocolData: type, comptime ProtocolConfig: type) type {
    return *const fn (
        provision: *ZProvision(ProtocolData),
        p_config: ProtocolConfig,
        z_config: zzzConfig,
        backend: *Async,
        recv_buffer: []const u8,
    ) RecvStatus;
}

pub fn Server(
    comptime security: Security,
    comptime ProtocolData: type,
    comptime ProtocolConfig: type,
    /// This is called after the Accept.
    comptime accept_fn: ?AcceptFn(ProtocolData, ProtocolConfig),
    /// This is called after the Recv.
    comptime recv_fn: RecvFn(ProtocolData, ProtocolConfig),
) type {
    const TLSContextType = if (comptime security == .tls) TLSContext else void;
    const Provision = ZProvision(ProtocolData);
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        config: zzzConfig,
        socket: ?Socket = null,
        tls_ctx: TLSContextType,
        backend_type: AsyncType,

        pub fn init(config: zzzConfig, async_type: ?AsyncType) Self {
            const backend_type = async_type orelse AutoAsyncType;

            const tls_ctx = switch (comptime security) {
                .tls => |inner| TLSContext.init(.{
                    .allocator = config.allocator,
                    .cert = inner.cert,
                    .cert_name = inner.cert_name,
                    .key = inner.key,
                    .key_name = inner.key_name,
                    .size_tls_buffer_max = config.size_socket_buffer * 2,
                }) catch unreachable,
                .plain => void{},
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
                switch (comptime Socket) {
                    std.posix.socket_t => std.posix.close(socket),
                    std.os.windows.ws2_32.SOCKET => std.os.windows.closesocket(socket),
                    else => {},
                }
            }

            if (comptime security == .tls) {
                self.tls_ctx.deinit();
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
                const socket_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
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

        /// Cleans up the TLS instance.
        inline fn clean_tls(tls_ptr: *?TLS) void {
            defer tls_ptr.* = null;

            assert(tls_ptr.* != null);
            tls_ptr.*.?.deinit();
        }

        fn clean_connection(
            provision: *Provision,
            provision_pool: *Pool(Provision),
            config: zzzConfig,
        ) void {
            defer provision_pool.release(provision.index);

            log.info("{d} - closing connection", .{provision.index});
            _ = provision.arena.reset(.{ .retain_with_limit = config.size_connection_arena_retain });
            provision.data.clean();
            std.posix.close(provision.socket);
        }

        fn run(
            z_config: zzzConfig,
            p_config: ProtocolConfig,
            backend: *Async,
            tls_ctx: TLSContextType,
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
                }

                provision_pool.deinit(Provision.deinit_hook, z_config);
            }

            // If we don't have TLS set, this becomes 0 sized.
            const tls_pool = blk: {
                switch (comptime security) {
                    .tls => |_| {
                        const pool = try z_config.allocator.alloc(?TLS, z_config.size_connections_max);
                        for (pool) |*tls| {
                            tls.* = null;
                        }

                        break :blk pool;
                    },
                    .plain => break :blk void{},
                }
            };

            defer {
                if (comptime security == .tls) {
                    for (tls_pool) |*tls| {
                        if (tls.*) |_| {
                            clean_tls(tls);
                        }
                    }

                    z_config.allocator.free(tls_pool);
                }
            }

            // Create and send the first Job.
            var first_provision = Provision{
                .job = .accept,
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
                        .accept => {
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

                            switch (comptime Socket) {
                                std.posix.socket_t => {
                                    try std.posix.setsockopt(
                                        socket,
                                        std.posix.IPPROTO.TCP,
                                        std.posix.TCP.NODELAY,
                                        &std.mem.toBytes(@as(c_int, 1)),
                                    );

                                    // Set this socket as non-blocking.
                                    const current_flags = try std.posix.fcntl(socket, std.posix.F.GETFL, 0);
                                    var new_flags = @as(std.os.linux.O, @bitCast(@as(u32, @intCast(current_flags))));
                                    new_flags.NONBLOCK = true;
                                    const arg: u32 = @bitCast(new_flags);
                                    _ = try std.posix.fcntl(socket, std.posix.F.SETFL, arg);
                                },
                                else => {},
                            }

                            const provision = borrowed.item;

                            // Store the index of this item.
                            provision.index = @intCast(borrowed.index);
                            provision.socket = socket;
                            provision.job = .{ .recv = .{ .count = 0 } };

                            switch (comptime security) {
                                .tls => |_| {
                                    const tls_ptr: *?TLS = &tls_pool[provision.index];
                                    assert(tls_ptr.* == null);

                                    tls_ptr.* = tls_ctx.create(socket) catch |e| {
                                        log.debug("{d} - tls creation failed={any}", .{ provision.index, e });
                                        clean_connection(provision, &provision_pool, z_config);
                                        continue :reap_loop;
                                    };

                                    tls_ptr.*.?.accept() catch |e| {
                                        clean_tls(tls_ptr);
                                        log.debug("{d} - tls handshake failed={any}", .{ provision.index, e });
                                        clean_connection(provision, &provision_pool, z_config);
                                        continue :reap_loop;
                                    };
                                },
                                .plain => {},
                            }

                            // Call the Accept Hook.
                            if (comptime accept_fn) |func| {
                                @call(.auto, func, .{ provision, p_config, z_config, backend });
                            }

                            _ = try backend.queue_recv(provision, provision.socket, provision.buffer);
                        },

                        .recv => |*inner| {
                            log.debug("{d} - recv triggered", .{p.index});

                            // If the socket is closed.
                            if (completion.result <= 0) {
                                if (comptime security == .tls) {
                                    const tls_ptr: *?TLS = &tls_pool[p.index];
                                    clean_tls(tls_ptr);
                                }

                                clean_connection(p, &provision_pool, z_config);
                                continue :reap_loop;
                            }

                            const read_count: u32 = @intCast(completion.result);
                            inner.count += read_count;
                            const pre_recv_buffer = p.buffer[0..read_count];

                            const recv_buffer = blk: {
                                switch (comptime security) {
                                    .tls => |_| {
                                        const tls_ptr: *?TLS = &tls_pool[p.index];
                                        assert(tls_ptr.* != null);

                                        break :blk tls_ptr.*.?.decrypt(pre_recv_buffer) catch |e| {
                                            log.debug("{d} - decrypt failed: {any}", .{ p.index, e });
                                            clean_tls(tls_ptr);
                                            clean_connection(p, &provision_pool, z_config);
                                            continue :reap_loop;
                                        };
                                    },
                                    .plain => break :blk pre_recv_buffer,
                                }
                            };

                            var status: RecvStatus = @call(.auto, recv_fn, .{
                                p,
                                p_config,
                                z_config,
                                backend,
                                recv_buffer,
                            });

                            switch (status) {
                                .kill => {
                                    return;
                                },
                                .recv => {
                                    try backend.queue_recv(p, p.socket, p.buffer);
                                },
                                .send => |*pslice| {
                                    const plain_buffer = pslice.get(0, z_config.size_socket_buffer);

                                    switch (comptime security) {
                                        .tls => |_| {
                                            const tls_ptr: *?TLS = &tls_pool[p.index];
                                            assert(tls_ptr.* != null);

                                            const encrypted_buffer = tls_ptr.*.?.encrypt(plain_buffer) catch {
                                                clean_tls(tls_ptr);
                                                clean_connection(p, &provision_pool, z_config);
                                                continue :reap_loop;
                                            };

                                            p.job = .{
                                                .send = .{
                                                    .tls = .{
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
                                                .send = .{
                                                    .plain = .{
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

                        .send => |*send_type| {
                            log.debug("{d} - send triggered", .{p.index});
                            const send_count = completion.result;

                            if (send_count <= 0) {
                                if (comptime security == .tls) {
                                    const tls_ptr: *?TLS = &tls_pool[p.index];
                                    clean_tls(tls_ptr);
                                }

                                clean_connection(p, &provision_pool, z_config);
                                continue :reap_loop;
                            }

                            switch (comptime security) {
                                .tls => {
                                    // This is for when sending encrypted data.
                                    assert(send_type.* == .tls);

                                    const inner = &send_type.tls;
                                    inner.encrypted_count += @intCast(send_count);

                                    if (inner.encrypted_count >= inner.encrypted.len) {
                                        if (inner.count >= inner.slice.len) {
                                            // All done sending.
                                            log.debug("{d} - queueing a new recv", .{p.index});
                                            _ = p.arena.reset(.{
                                                .retain_with_limit = z_config.size_connection_arena_retain,
                                            });
                                            p.recv_buffer.clearRetainingCapacity();
                                            p.job = .{ .recv = .{ .count = 0 } };
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

                                            const tls_ptr: *?TLS = &tls_pool[p.index];
                                            assert(tls_ptr.* != null);

                                            const encrypted = tls_ptr.*.?.encrypt(inner_slice) catch {
                                                clean_tls(tls_ptr);
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
                                .plain => {
                                    // This is for when sending plaintext.
                                    assert(send_type.* == .plain);

                                    const inner = &send_type.plain;
                                    inner.count += @intCast(send_count);

                                    if (inner.count >= inner.slice.len) {
                                        log.debug("{d} - queueing a new recv", .{p.index});
                                        _ = p.arena.reset(.{
                                            .retain_with_limit = z_config.size_connection_arena_retain,
                                        });
                                        p.recv_buffer.clearRetainingCapacity();
                                        p.job = .{ .recv = .{ .count = 0 } };
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
                            }
                        },

                        .close => {},

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
            log.info("security mode: {s}", .{@tagName(security)});

            switch (comptime Socket) {
                std.posix.socket_t => try std.posix.listen(server_socket, self.config.size_backlog),
                else => unreachable,
            }

            var backend = blk: {
                switch (self.backend_type) {
                    .io_uring => {
                        // Initalize IO Uring
                        const base_flags = std.os.linux.IORING_SETUP_COOP_TASKRUN | std.os.linux.IORING_SETUP_SINGLE_ISSUER;

                        const uring = try self.allocator.create(std.os.linux.IoUring);
                        uring.* = try std.os.linux.IoUring.init(
                            std.math.ceilPowerOfTwoAssert(u16, self.config.size_connections_max),
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
                            .auto => break :blk @max((std.Thread.getCpuCount() catch break :blk 2) / 2 - 1, 2),
                            .count => |inner| break :blk inner,
                        }
                    };

                    log.info("spawning {d} thread[s]", .{thread_count});

                    // spawn (count-1) new threads.
                    for (0..thread_count - 1) |i| {
                        try threads.append(try std.Thread.spawn(.{ .allocator = allocator }, struct {
                            fn handler_fn(
                                p_config: ProtocolConfig,
                                z_config: zzzConfig,
                                p_backend: Async,
                                backend_type: AsyncType,
                                thread_tls_ctx: TLSContextType,
                                s_socket: Socket,
                                thread_id: usize,
                            ) void {
                                var thread_backend = blk: {
                                    switch (backend_type) {
                                        .io_uring => {
                                            const parent_uring: *std.os.linux.IoUring = @ptrCast(@alignCast(p_backend.runner));
                                            assert(parent_uring.fd >= 0);

                                            // Initalize IO Uring
                                            const thread_flags = std.os.linux.IORING_SETUP_COOP_TASKRUN | std.os.linux.IORING_SETUP_SINGLE_ISSUER | std.os.linux.IORING_SETUP_ATTACH_WQ;

                                            var params = std.mem.zeroInit(std.os.linux.io_uring_params, .{
                                                .flags = thread_flags,
                                                .wq_fd = @as(u32, @intCast(parent_uring.fd)),
                                            });

                                            const uring = z_config.allocator.create(std.os.linux.IoUring) catch unreachable;
                                            uring.* = std.os.linux.IoUring.init_params(
                                                std.math.ceilPowerOfTwoAssert(u16, z_config.size_connections_max),
                                                &params,
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
                        }.handler_fn, .{ protocol_config, self.config, backend, self.backend_type, self.tls_ctx, server_socket, i }));
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
