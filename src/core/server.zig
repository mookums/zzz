const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/server");

const Completion = @import("../async/completion.zig").Completion;
const CompletionResult = @import("../async/completion.zig").CompletionResult;
const Async = @import("../async/lib.zig").Async;
const AsyncOptions = @import("../async/lib.zig").AsyncOptions;
const auto_async_match = @import("../async/lib.zig").auto_async_match;
const AsyncType = @import("../async/lib.zig").AsyncType;
const AsyncIoUring = @import("../async/io_uring.zig").AsyncIoUring;
const AsyncEpoll = @import("../async/epoll.zig").AsyncEpoll;
const AsyncBusyLoop = @import("../async/busy_loop.zig").AsyncBusyLoop;

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
    /// Number of Maximum Concurrent Connections.
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
    /// Maximum number of completions we can reap
    /// with a single call of reap().
    ///
    /// Default: 256
    size_completions_reap_max: u16 = 256,
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
    /// Length of the timeout that each operation has
    /// before it is forcibly closed.
    ///
    /// Set to null to disable timeouts.
    ///
    /// Default: 5000ms (5 seconds).
    ms_operation_max: ?u32 = 5000,
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
    comptime pre_async_type: AsyncType,
    comptime ProtocolData: type,
    comptime ProtocolConfig: type,
    /// This is called after the Accept.
    comptime accept_fn: ?AcceptFn(ProtocolData, ProtocolConfig),
    /// This is called after the Recv.
    comptime recv_fn: RecvFn(ProtocolData, ProtocolConfig),
) type {
    const TLSContextType = comptime if (security == .tls) TLSContext else void;
    const Provision = ZProvision(ProtocolData);
    const async_type = comptime if (pre_async_type == .auto) auto_async_match() else pre_async_type;

    comptime {
        if (async_type == .custom) {
            assert(std.meta.hasMethod(async_type.custom, "init"));
            assert(std.meta.hasMethod(async_type.custom, "to_async"));
        }
    }

    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        config: zzzConfig,
        socket: ?Socket = null,
        tls_ctx: TLSContextType,

        pub fn init(config: zzzConfig) Self {
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
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.socket) |socket| {
                switch (comptime Socket) {
                    std.posix.socket_t => std.posix.close(socket),
                    else => unreachable,
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

            const addr = blk: {
                switch (comptime builtin.os.tag) {
                    .windows => break :blk try std.net.Address.parseIp(host, port),
                    else => break :blk try std.net.Address.resolveIp(host, port),
                }
            };

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
        fn clean_tls(tls_ptr: *?TLS) void {
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
            std.posix.close(provision.socket);
            switch (comptime builtin.target.os.tag) {
                .windows => provision.socket = std.os.windows.ws2_32.INVALID_SOCKET,
                else => provision.socket = -1,
            }
            provision.job = .accept;
            _ = provision.arena.reset(.{ .retain_with_limit = config.size_connection_arena_retain });
            provision.data.clean();
            provision.recv_buffer.clearRetainingCapacity();
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

            _ = try backend.queue_accept(
                &first_provision,
                server_socket,
            );
            try backend.submit();

            var accept_queued = true;

            while (true) {
                const completions = try backend.reap();
                const completions_count = completions.len;
                assert(completions_count > 0);
                log.debug("Completion Count: {d}", .{completions_count});

                reap_loop: for (completions[0..completions_count]) |completion| {
                    const p: *Provision = @ptrCast(@alignCast(completion.context));

                    // If the operation has completed before the timeout.
                    // This is the timeout SQE.
                    if (completion.result == .already) {
                        log.debug("Already: {s}", .{@tagName(p.job)});
                        continue :reap_loop;
                    }

                    // If the timeout has completed before the operation.
                    // This is the acutal SQE.
                    if (completion.result == .canceled) {
                        log.debug("Canceled: {s}", .{@tagName(p.job)});
                        continue :reap_loop;
                    }

                    // Timeout finished before operation.
                    // This is a timeout SQE.
                    if (completion.result == .timeout) {
                        log.debug("Timed Out: {s}", .{@tagName(p.job)});
                        if (p.job == .accept) {
                            accept_queued = false;
                        } else {
                            if (comptime security == .tls) {
                                const tls_ptr: *?TLS = &tls_pool[p.index];
                                clean_tls(tls_ptr);
                            }

                            clean_connection(p, &provision_pool, z_config);
                        }
                        continue :reap_loop;
                    }

                    switch (p.job) {
                        .accept => {
                            log.info("connection accepted!", .{});
                            accept_queued = false;
                            const socket: Socket = completion.result.socket;

                            const index = blk: {
                                switch (comptime builtin.target.os.tag) {
                                    .windows => {
                                        if (socket == std.os.windows.ws2_32.INVALID_SOCKET) {
                                            log.err("socket accept failed", .{});
                                            continue :reap_loop;
                                        }

                                        break :blk 0;
                                    },
                                    else => {
                                        if (socket < 0) {
                                            log.err("socket accept failed", .{});
                                            continue :reap_loop;
                                        }

                                        break :blk socket;
                                    },
                                }
                            };

                            // Borrow a provision from the pool otherwise close the socket.
                            const borrowed = provision_pool.borrow(@intCast(index)) catch {
                                log.warn("out of provision pool entries", .{});
                                std.posix.close(socket);
                                continue :reap_loop;
                            };

                            switch (comptime Socket) {
                                std.posix.socket_t => {
                                    // Disable Nagle's
                                    if (comptime builtin.os.tag.isDarwin()) {
                                        // system.TCP is weird on MacOS.
                                        try std.posix.setsockopt(
                                            socket,
                                            std.posix.IPPROTO.TCP,
                                            1,
                                            &std.mem.toBytes(@as(c_int, 1)),
                                        );
                                    } else {
                                        try std.posix.setsockopt(
                                            socket,
                                            std.posix.IPPROTO.TCP,
                                            std.posix.TCP.NODELAY,
                                            &std.mem.toBytes(@as(c_int, 1)),
                                        );
                                    }

                                    // Set non-blocking.
                                    switch (comptime builtin.target.os.tag) {
                                        .windows => {
                                            var mode: u32 = 1;
                                            _ = std.os.windows.ws2_32.ioctlsocket(
                                                socket,
                                                std.os.windows.ws2_32.FIONBIO,
                                                &mode,
                                            );
                                        },
                                        else => {
                                            const current_flags = try std.posix.fcntl(socket, std.posix.F.GETFL, 0);
                                            var new_flags = @as(
                                                std.posix.O,
                                                @bitCast(@as(u32, @intCast(current_flags))),
                                            );
                                            new_flags.NONBLOCK = true;
                                            const arg: u32 = @bitCast(new_flags);
                                            _ = try std.posix.fcntl(socket, std.posix.F.SETFL, arg);
                                        },
                                    }
                                },
                                else => unreachable,
                            }

                            const provision = borrowed.item;

                            // Store the index of this item.
                            provision.index = @intCast(borrowed.index);
                            provision.socket = socket;

                            var buffer: []u8 = provision.buffer;

                            switch (comptime security) {
                                .tls => |_| {
                                    const tls_ptr: *?TLS = &tls_pool[provision.index];
                                    assert(tls_ptr.* == null);

                                    tls_ptr.* = tls_ctx.create(socket) catch |e| {
                                        log.debug("{d} - tls creation failed={any}", .{ provision.index, e });
                                        clean_connection(provision, &provision_pool, z_config);
                                        continue :reap_loop;
                                    };

                                    const recv_buf = tls_ptr.*.?.start_handshake() catch |e| {
                                        clean_tls(tls_ptr);
                                        log.debug("{d} - tls reset failed={any}", .{ provision.index, e });
                                        clean_connection(provision, &provision_pool, z_config);
                                        continue :reap_loop;
                                    };

                                    provision.job = .{ .handshake = .{ .state = .recv, .count = 0 } };
                                    buffer = recv_buf;
                                },
                                .plain => {
                                    provision.job = .{ .recv = .{ .count = 0 } };
                                },
                            }

                            // Call the Accept Hook.
                            if (comptime accept_fn) |func| {
                                @call(.auto, func, .{ provision, p_config, z_config, backend });
                            }

                            _ = try backend.queue_recv(
                                provision,
                                provision.socket,
                                buffer,
                            );
                        },

                        .handshake => |*inner| {
                            assert(comptime security == .tls);
                            if (comptime security == .tls) {
                                const tls_ptr: *?TLS = &tls_pool[p.index];
                                assert(tls_ptr.* != null);
                                log.debug("processing handshake", .{});
                                inner.count += 1;

                                if (completion.result.value < 0 or inner.count >= 50) {
                                    clean_tls(tls_ptr);
                                    clean_connection(p, &provision_pool, z_config);
                                    continue :reap_loop;
                                }

                                const length: usize = @intCast(completion.result.value);

                                switch (inner.state) {
                                    .recv => {
                                        // on recv, we want to read from socket and feed into tls engien
                                        const hstate = tls_ptr.*.?.continue_handshake(
                                            .{ .recv = @intCast(length) },
                                        ) catch |e| {
                                            clean_tls(tls_ptr);
                                            log.debug("{d} - tls handshake on recv failed={any}", .{ p.index, e });
                                            clean_connection(p, &provision_pool, z_config);
                                            continue :reap_loop;
                                        };

                                        switch (hstate) {
                                            .recv => |buf| {
                                                log.debug("requeing recv in handshake", .{});
                                                _ = try backend.queue_recv(
                                                    p,
                                                    p.socket,
                                                    buf,
                                                );
                                            },
                                            .send => |buf| {
                                                log.debug("queueing send in handshake", .{});
                                                inner.state = .send;
                                                _ = try backend.queue_send(
                                                    p,
                                                    p.socket,
                                                    buf,
                                                );
                                            },
                                            .complete => {
                                                log.debug("handshake complete", .{});
                                                p.job = .{ .recv = .{ .count = 0 } };
                                                _ = try backend.queue_recv(
                                                    p,
                                                    p.socket,
                                                    p.buffer,
                                                );
                                            },
                                        }
                                    },
                                    .send => {
                                        // on recv, we want to read from socket and feed into tls engien
                                        const hstate = tls_ptr.*.?.continue_handshake(
                                            .{ .send = @intCast(length) },
                                        ) catch |e| {
                                            clean_tls(tls_ptr);
                                            log.debug("{d} - tls handshake on send failed={any}", .{ p.index, e });
                                            clean_connection(p, &provision_pool, z_config);
                                            continue :reap_loop;
                                        };

                                        switch (hstate) {
                                            .recv => |buf| {
                                                inner.state = .recv;
                                                log.debug("queuing recv in handshake", .{});
                                                _ = try backend.queue_recv(
                                                    p,
                                                    p.socket,
                                                    buf,
                                                );
                                            },
                                            .send => |buf| {
                                                log.debug("requeing send in handshake", .{});
                                                _ = try backend.queue_send(
                                                    p,
                                                    p.socket,
                                                    buf,
                                                );
                                            },
                                            .complete => {
                                                log.debug("handshake complete", .{});
                                                p.job = .{ .recv = .{ .count = 0 } };
                                                _ = try backend.queue_recv(
                                                    p,
                                                    p.socket,
                                                    p.buffer,
                                                );
                                            },
                                        }
                                    },
                                }
                            } else unreachable;
                        },

                        .recv => |*inner| {
                            log.debug("{d} - recv triggered", .{p.index});

                            // If the socket is closed.
                            if (completion.result.value <= 0) {
                                if (comptime security == .tls) {
                                    const tls_ptr: *?TLS = &tls_pool[p.index];
                                    clean_tls(tls_ptr);
                                }

                                clean_connection(p, &provision_pool, z_config);
                                continue :reap_loop;
                            }

                            const read_count: u32 = @intCast(completion.result.value);
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
                                    try backend.queue_recv(
                                        p,
                                        p.socket,
                                        p.buffer,
                                    );
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

                                            try backend.queue_send(
                                                p,
                                                p.socket,
                                                encrypted_buffer,
                                            );
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
                                            try backend.queue_send(
                                                p,
                                                p.socket,
                                                plain_buffer,
                                            );
                                        },
                                    }
                                },
                            }
                        },

                        .send => |*send_type| {
                            log.debug("{d} - send triggered", .{p.index});
                            const send_count = completion.result.value;

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
                                            try backend.queue_recv(
                                                p,
                                                p.socket,
                                                p.buffer,
                                            );
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

                                            try backend.queue_send(
                                                p,
                                                p.socket,
                                                inner.encrypted,
                                            );
                                        }
                                    } else {
                                        log.debug(
                                            "{d} - sending next encrypted chunk starting at index {d}",
                                            .{ p.index, inner.encrypted_count },
                                        );

                                        const remainder = inner.encrypted[inner.encrypted_count..];
                                        try backend.queue_send(
                                            p,
                                            p.socket,
                                            remainder,
                                        );
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
                                        try backend.queue_recv(
                                            p,
                                            p.socket,
                                            p.buffer,
                                        );
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

                                        try backend.queue_send(
                                            p,
                                            p.socket,
                                            plain_buffer,
                                        );
                                    }
                                },
                            }
                        },

                        .close => {},

                        else => @panic("not implemented yet!"),
                    }
                }

                if (!accept_queued and !provision_pool.full()) {
                    _ = try backend.queue_accept(&first_provision, server_socket);
                    accept_queued = true;
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
            log.info("async backend: {s}", .{@tagName(async_type)});

            switch (comptime Socket) {
                std.posix.socket_t => try std.posix.listen(server_socket, self.config.size_backlog),
                // TODO: Handle freestanding targets that use an u32 here.
                else => unreachable,
            }

            var backend = blk: {
                const options: AsyncOptions = .{
                    .root_async = null,
                    .in_thread = false,
                    .size_connections_max = self.config.size_connections_max,
                    .ms_operation_max = 3000,
                };

                switch (comptime async_type) {
                    .io_uring => {
                        var uring = try AsyncIoUring(Provision).init(
                            self.allocator,
                            options,
                        );

                        break :blk uring.to_async();
                    },
                    .epoll => {
                        var epoll = try AsyncEpoll.init(
                            self.allocator,
                            options,
                        );

                        break :blk epoll.to_async();
                    },
                    .busy_loop => {
                        var busy = try AsyncBusyLoop.init(
                            self.allocator,
                            options,
                        );

                        break :blk busy.to_async();
                    },
                    .custom => |inner| {
                        var custom = try inner.init(
                            self.allocator,
                            options,
                        );

                        break :blk custom.to_async();
                    },
                    .auto => unreachable,
                }
            };

            {
                const completions = try self.allocator.alloc(
                    Completion,
                    self.config.size_completions_reap_max,
                );

                backend.attach(completions);
            }

            defer {
                self.allocator.free(backend.completions);
                backend.deinit(self.allocator);
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
                        try threads.append(try std.Thread.spawn(
                            .{ .allocator = allocator },
                            struct {
                                fn handler_fn(
                                    p_config: ProtocolConfig,
                                    z_config: zzzConfig,
                                    p_backend: Async,
                                    thread_tls_ctx: TLSContextType,
                                    s_socket: Socket,
                                    thread_id: usize,
                                ) void {
                                    var thread_backend = blk: {
                                        const options: AsyncOptions = .{
                                            .root_async = p_backend,
                                            .in_thread = true,
                                            .size_connections_max = z_config.size_connections_max,
                                            .ms_operation_max = 3000,
                                        };

                                        switch (comptime async_type) {
                                            .io_uring => {
                                                var uring = AsyncIoUring(Provision).init(
                                                    z_config.allocator,
                                                    options,
                                                ) catch unreachable;

                                                break :blk uring.to_async();
                                            },
                                            .epoll => {
                                                var epoll = AsyncEpoll.init(
                                                    z_config.allocator,
                                                    options,
                                                ) catch unreachable;

                                                break :blk epoll.to_async();
                                            },
                                            .busy_loop => {
                                                var busy = AsyncBusyLoop.init(
                                                    z_config.allocator,
                                                    options,
                                                ) catch unreachable;

                                                break :blk busy.to_async();
                                            },
                                            .custom => |AsyncCustom| {
                                                var custom = AsyncCustom.init(
                                                    z_config.allocator,
                                                    options,
                                                ) catch unreachable;

                                                break :blk custom.to_async();
                                            },
                                            .auto => unreachable,
                                        }
                                    };

                                    {
                                        const completions = z_config.allocator.alloc(
                                            Completion,
                                            z_config.size_completions_reap_max,
                                        ) catch unreachable;

                                        thread_backend.attach(completions);
                                    }

                                    defer {
                                        z_config.allocator.free(thread_backend.completions);
                                        thread_backend.deinit(z_config.allocator);
                                    }

                                    run(z_config, p_config, &thread_backend, thread_tls_ctx, s_socket) catch |e| {
                                        log.err("thread #{d} failed due to unrecoverable error: {any}", .{ thread_id, e });
                                    };
                                }
                            }.handler_fn,
                            .{
                                protocol_config,
                                self.config,
                                backend,
                                self.tls_ctx,
                                server_socket,
                                i,
                            },
                        ));
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
