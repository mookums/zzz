const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/server");

const Pseudoslice = @import("pseudoslice.zig").Pseudoslice;
const ZProvision = @import("zprovision.zig").ZProvision;

const TLSFileOptions = @import("../tls/lib.zig").TLSFileOptions;
const TLSContext = @import("../tls/lib.zig").TLSContext;
const TLS = @import("../tls/lib.zig").TLS;

const Pool = @import("tardy").Pool;
pub const Threading = @import("tardy").TardyThreading;
pub const Runtime = @import("tardy").Runtime;
pub const Task = @import("tardy").Task;
pub const AsyncIOType = @import("tardy").AsyncIOType;
const TardyCreator = @import("tardy").Tardy;

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
    /// Default: .auto
    threading: Threading = .auto,
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
    /// should make allocators faster.Tardy
    ///
    /// A lower value will reduce memory usage but
    /// will make allocators slower.
    ///
    /// Default: 1KB
    size_connection_arena_retain: u32 = 1024,
    /// Size of the buffer (in bytes) used for
    /// interacting with the socket.
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

fn RecvFn(comptime ProtocolData: type, comptime ProtocolConfig: type) type {
    return *const fn (
        rt: *Runtime,
        provision: *ZProvision(ProtocolData),
        p_config: *const ProtocolConfig,
        z_config: *const zzzConfig,
        recv_buffer: []const u8,
    ) RecvStatus;
}

pub fn Server(
    comptime security: Security,
    comptime async_type: AsyncIOType,
    comptime ProtocolData: type,
    comptime ProtocolConfig: type,
    comptime recv_fn: RecvFn(ProtocolData, ProtocolConfig),
) type {
    const TLSContextType = comptime if (security == .tls) TLSContext else void;
    const TLSType = comptime if (security == .tls) ?TLS else void;
    const Provision = ZProvision(ProtocolData);
    const Tardy = TardyCreator(async_type);

    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        tardy: Tardy,
        config: zzzConfig,
        addr: std.net.Address,
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
                .tardy = Tardy.init(.{
                    .allocator = config.allocator,
                    .threading = config.threading,
                    .size_tasks_max = config.size_connections_max,
                    .size_aio_jobs_max = config.size_connections_max,
                    .size_aio_reap_max = config.size_completions_reap_max,
                }) catch unreachable,
                .config = config,
                .addr = undefined,
                .tls_ctx = tls_ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            if (comptime security == .tls) {
                self.tls_ctx.deinit();
            }

            self.tardy.deinit();
        }

        fn create_socket(self: *const Self) !std.posix.socket_t {
            const socket: std.posix.socket_t = blk: {
                const socket_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK;
                break :blk try std.posix.socket(
                    self.addr.any.family,
                    socket_flags,
                    std.posix.IPPROTO.TCP,
                );
            };

            log.debug("socket | t: {s} v: {any}", .{ @typeName(std.posix.socket_t), socket });

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

            try std.posix.bind(socket, &self.addr.any, self.addr.getOsSockLen());
            return socket;
        }

        /// If you are using a custom implementation that does NOT rely
        /// on TCP/IP, you can SKIP calling this method and just set the
        /// socket value yourself.
        ///
        /// This is only allowed on certain targets that do not have TCP/IP
        /// support.
        pub fn bind(self: *Self, host: []const u8, port: u16) !void {
            assert(host.len > 0);
            assert(port > 0);

            self.addr = blk: {
                switch (comptime builtin.os.tag) {
                    .windows => break :blk try std.net.Address.parseIp(host, port),
                    else => break :blk try std.net.Address.resolveIp(host, port),
                }
            };
        }

        fn close_task(rt: *Runtime, _: *const Task, ctx: ?*anyopaque) !void {
            const provision: *Provision = @ptrCast(@alignCast(ctx.?));
            assert(provision.job == .close);
            const server_socket: *std.posix.socket_t = @ptrCast(@alignCast(rt.storage.get("server_socket").?));
            const pool: *Pool(Provision) = @ptrCast(@alignCast(rt.storage.get("provision_pool").?));
            const z_config: *const zzzConfig = @ptrCast(@alignCast(rt.storage.get("z_config").?));

            log.info("{d} - closing connection", .{provision.index});

            if (comptime security == .tls) {
                const tls_slice: []TLSType = @as(
                    [*]TLSType,
                    @ptrCast(@alignCast(rt.storage.get("tls_slice").?)),
                )[0..z_config.size_connections_max];

                const tls_ptr: *?TLS = &tls_slice[provision.index];
                assert(tls_ptr.* != null);
                tls_ptr.*.?.deinit();
                tls_ptr.* = null;
            }

            switch (comptime builtin.target.os.tag) {
                .windows => {
                    provision.socket = std.os.windows.ws2_32.INVALID_SOCKET;
                },
                else => {
                    provision.socket = -1;
                },
            }

            provision.job = .empty;
            _ = provision.arena.reset(.{ .retain_with_limit = z_config.size_connection_arena_retain });
            provision.data.clean();
            provision.recv_buffer.clearRetainingCapacity();
            pool.release(provision.index);

            const accept_queued: *bool = @ptrCast(@alignCast(rt.storage.get("accept_queued").?));
            if (!accept_queued.*) {
                accept_queued.* = true;
                try rt.net.accept(.{
                    .socket = server_socket.*,
                    .func = accept_task,
                });
            }
        }

        fn accept_task(rt: *Runtime, t: *const Task, _: ?*anyopaque) !void {
            const child_socket = t.result.?.socket;

            const pool: *Pool(Provision) = @ptrCast(@alignCast(rt.storage.get("provision_pool").?));
            const z_config: *const zzzConfig = @ptrCast(@alignCast(rt.storage.get("z_config").?));

            const accept_queued: *bool = @ptrCast(@alignCast(rt.storage.get("accept_queued").?));
            accept_queued.* = false;

            if (rt.scheduler.tasks.clean() >= 2) {
                accept_queued.* = true;
                const server_socket: *std.posix.socket_t = @ptrCast(@alignCast(rt.storage.get("server_socket").?));
                try rt.net.accept(.{
                    .socket = server_socket.*,
                    .func = accept_task,
                });
            }

            switch (comptime builtin.target.os.tag) {
                .windows => {
                    if (child_socket == std.os.windows.ws2_32.INVALID_SOCKET) {
                        log.err("socket accept failed", .{});
                        return error.AcceptFailed;
                    }
                },
                else => {
                    if (child_socket <= 0) {
                        log.err("socket accept failed", .{});
                        return error.AcceptFailed;
                    }
                },
            }

            // This should never fail. It means that we have a dangling item.
            assert(pool.clean() > 0);
            const borrowed = pool.borrow_hint(t.index) catch unreachable;

            log.info("{d} - accepting connection", .{borrowed.index});
            log.debug(
                "empty provision slots: {d}",
                .{pool.items.len - pool.dirty.count()},
            );
            assert(borrowed.item.job == .empty);

            switch (comptime std.posix.socket_t) {
                std.posix.socket_t => {
                    // Disable Nagle's
                    if (comptime builtin.os.tag.isDarwin()) {
                        // system.TCP is weird on MacOS.
                        try std.posix.setsockopt(
                            child_socket,
                            std.posix.IPPROTO.TCP,
                            1,
                            &std.mem.toBytes(@as(c_int, 1)),
                        );
                    } else {
                        try std.posix.setsockopt(
                            child_socket,
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
                                child_socket,
                                std.os.windows.ws2_32.FIONBIO,
                                &mode,
                            );
                        },
                        else => {
                            const current_flags = try std.posix.fcntl(
                                child_socket,
                                std.posix.F.GETFL,
                                0,
                            );
                            var new_flags = @as(
                                std.posix.O,
                                @bitCast(@as(u32, @intCast(current_flags))),
                            );
                            new_flags.NONBLOCK = true;
                            const arg: u32 = @bitCast(new_flags);
                            _ = try std.posix.fcntl(child_socket, std.posix.F.SETFL, arg);
                        },
                    }
                },
                else => unreachable,
            }

            const provision = borrowed.item;

            // Store the index of this item.
            provision.index = @intCast(borrowed.index);
            provision.socket = child_socket;

            switch (comptime security) {
                .tls => |_| {
                    const tls_ctx: *TLSContextType = @ptrCast(@alignCast(rt.storage.get("tls_ctx").?));
                    const tls_slice: []TLSType = @as(
                        [*]TLSType,
                        @ptrCast(@alignCast(rt.storage.get("tls_slice").?)),
                    )[0..z_config.size_connections_max];

                    const tls_ptr: *?TLS = &tls_slice[provision.index];
                    assert(tls_ptr.* == null);

                    tls_ptr.* = tls_ctx.create(child_socket) catch |e| {
                        log.err("{d} - tls creation failed={any}", .{ provision.index, e });
                        provision.job = .close;
                        try rt.net.close(.{
                            .fd = provision.socket,
                            .func = close_task,
                            .ctx = provision,
                        });
                        return error.TLSCreationFailed;
                    };

                    const recv_buf = tls_ptr.*.?.start_handshake() catch |e| {
                        log.err("{d} - tls start handshake failed={any}", .{ provision.index, e });
                        provision.job = .close;
                        try rt.net.close(.{
                            .fd = provision.socket,
                            .func = close_task,
                            .ctx = provision,
                        });
                        return error.TLSStartHandshakeFailed;
                    };

                    provision.job = .{ .handshake = .{ .state = .recv, .count = 0 } };
                    try rt.net.recv(.{
                        .socket = child_socket,
                        .buffer = recv_buf,
                        .func = handshake_task,
                        .ctx = borrowed.item,
                    });
                },
                .plain => {
                    provision.job = .{ .recv = .{ .count = 0 } };
                    try rt.net.recv(.{
                        .socket = child_socket,
                        .buffer = provision.buffer,
                        .func = recv_task,
                        .ctx = borrowed.item,
                    });
                },
            }
        }

        fn recv_task(rt: *Runtime, t: *const Task, ctx: ?*anyopaque) !void {
            const provision: *Provision = @ptrCast(@alignCast(ctx.?));
            assert(provision.job == .recv);
            const length: i32 = t.result.?.value;

            const p_config: *const ProtocolConfig = @ptrCast(@alignCast(rt.storage.get("p_config").?));
            const z_config: *const zzzConfig = @ptrCast(@alignCast(rt.storage.get("z_config").?));

            const recv_job = &provision.job.recv;

            // If the socket is closed.
            if (length <= 0) {
                provision.job = .close;
                try rt.net.close(.{
                    .fd = provision.socket,
                    .func = close_task,
                    .ctx = provision,
                });
                return;
            }

            log.debug("{d} - recv triggered", .{provision.index});

            const recv_count: usize = @intCast(length);
            recv_job.count += recv_count;
            const pre_recv_buffer = provision.buffer[0..recv_count];

            const recv_buffer = blk: {
                switch (comptime security) {
                    .tls => |_| {
                        const tls_slice: []TLSType = @as(
                            [*]TLSType,
                            @ptrCast(@alignCast(rt.storage.get("tls_slice").?)),
                        )[0..z_config.size_connections_max];

                        const tls_ptr: *?TLS = &tls_slice[provision.index];
                        assert(tls_ptr.* != null);

                        break :blk tls_ptr.*.?.decrypt(pre_recv_buffer) catch |e| {
                            log.err("{d} - decrypt failed: {any}", .{ provision.index, e });
                            provision.job = .close;
                            try rt.net.close(.{
                                .fd = provision.socket,
                                .func = close_task,
                                .ctx = provision,
                            });
                            return error.TLSDecryptFailed;
                        };
                    },
                    .plain => break :blk pre_recv_buffer,
                }
            };

            var status: RecvStatus = recv_fn(rt, provision, p_config, z_config, recv_buffer);

            switch (status) {
                .kill => {
                    rt.stop();
                    return error.Killed;
                },
                .recv => {
                    try rt.net.recv(.{
                        .socket = provision.socket,
                        .buffer = provision.buffer,
                        .func = recv_task,
                        .ctx = provision,
                    });
                },
                .send => |*pslice| {
                    const plain_buffer = pslice.get(0, z_config.size_socket_buffer);

                    switch (comptime security) {
                        .tls => |_| {
                            const tls_slice: []TLSType = @as(
                                [*]TLSType,
                                @ptrCast(@alignCast(rt.storage.get("tls_slice").?)),
                            )[0..z_config.size_connections_max];

                            const tls_ptr: *?TLS = &tls_slice[provision.index];
                            assert(tls_ptr.* != null);

                            const encrypted_buffer = tls_ptr.*.?.encrypt(plain_buffer) catch |e| {
                                log.err("{d} - encrypt failed: {any}", .{ provision.index, e });
                                provision.job = .close;
                                try rt.net.close(.{
                                    .fd = provision.socket,
                                    .func = close_task,
                                    .ctx = provision,
                                });
                                return error.TLSEncryptFailed;
                            };

                            provision.job = .{
                                .send = .{
                                    .slice = pslice.*,
                                    .count = @intCast(plain_buffer.len),
                                    .security = .{
                                        .tls = .{
                                            .encrypted = encrypted_buffer,
                                            .encrypted_count = 0,
                                        },
                                    },
                                },
                            };

                            try rt.net.send(.{
                                .socket = provision.socket,
                                .buffer = encrypted_buffer,
                                .func = send_task,
                                .ctx = provision,
                            });
                        },
                        .plain => {
                            provision.job = .{
                                .send = .{
                                    .slice = pslice.*,
                                    .count = 0,
                                    .security = .plain,
                                },
                            };

                            try rt.net.send(.{
                                .socket = provision.socket,
                                .buffer = plain_buffer,
                                .func = send_task,
                                .ctx = provision,
                            });
                        },
                    }
                },
            }
        }

        fn handshake_task(rt: *Runtime, t: *const Task, ctx: ?*anyopaque) !void {
            log.debug("Handshake Task", .{});
            assert(security == .tls);
            const provision: *Provision = @ptrCast(@alignCast(ctx.?));
            const length: i32 = t.result.?.value;

            const z_config: *const zzzConfig = @ptrCast(@alignCast(rt.storage.get("z_config").?));
            const tls_slice: []TLSType = @as(
                [*]TLSType,
                @ptrCast(@alignCast(rt.storage.get("tls_slice").?)),
            )[0..z_config.size_connections_max];

            if (comptime security == .tls) {
                assert(provision.job == .handshake);
                const handshake_job = &provision.job.handshake;

                const tls_ptr: *?TLS = &tls_slice[provision.index];
                assert(tls_ptr.* != null);
                log.debug("processing handshake", .{});
                handshake_job.count += 1;

                if (length <= 0) {
                    log.debug("handshake connection closed", .{});
                    provision.job = .close;
                    try rt.net.close(.{
                        .fd = provision.socket,
                        .func = close_task,
                        .ctx = provision,
                    });
                    return error.TLSHandshakeClosed;
                }

                if (handshake_job.count >= 50) {
                    log.debug("handshake taken too many cycles", .{});
                    provision.job = .close;
                    try rt.net.close(.{
                        .fd = provision.socket,
                        .func = close_task,
                        .ctx = provision,
                    });
                    return error.TLSHandshakeTooManyCycles;
                }

                const hs_length: usize = @intCast(length);

                switch (handshake_job.state) {
                    .recv => {
                        // on recv, we want to read from socket and feed into tls engien
                        const hstate = tls_ptr.*.?.continue_handshake(
                            .{ .recv = @intCast(hs_length) },
                        ) catch |e| {
                            log.err("{d} - tls handshake on recv failed={any}", .{ provision.index, e });
                            provision.job = .close;
                            try rt.net.close(.{
                                .fd = provision.socket,
                                .func = close_task,
                                .ctx = provision,
                            });
                            return error.TLSHandshakeRecvFailed;
                        };

                        switch (hstate) {
                            .recv => |buf| {
                                log.debug("requeing recv in handshake", .{});
                                try rt.net.recv(.{
                                    .socket = provision.socket,
                                    .buffer = buf,
                                    .func = handshake_task,
                                    .ctx = provision,
                                });
                            },
                            .send => |buf| {
                                log.debug("queueing send in handshake", .{});
                                handshake_job.state = .send;
                                try rt.net.send(.{
                                    .socket = provision.socket,
                                    .buffer = buf,
                                    .func = handshake_task,
                                    .ctx = provision,
                                });
                            },
                            .complete => {
                                log.debug("handshake complete", .{});
                                provision.job = .{ .recv = .{ .count = 0 } };
                                try rt.net.recv(.{
                                    .socket = provision.socket,
                                    .buffer = provision.buffer,
                                    .func = recv_task,
                                    .ctx = provision,
                                });
                            },
                        }
                    },
                    .send => {
                        // on recv, we want to read from socket and feed into tls engien
                        const hstate = tls_ptr.*.?.continue_handshake(
                            .{ .send = @intCast(hs_length) },
                        ) catch |e| {
                            log.err("{d} - tls handshake on send failed={any}", .{ provision.index, e });
                            provision.job = .close;
                            try rt.net.close(.{
                                .fd = provision.socket,
                                .func = close_task,
                                .ctx = provision,
                            });
                            return error.TLSHandshakeSendFailed;
                        };

                        switch (hstate) {
                            .recv => |buf| {
                                handshake_job.state = .recv;
                                log.debug("queuing recv in handshake", .{});
                                try rt.net.recv(.{
                                    .socket = provision.socket,
                                    .buffer = buf,
                                    .func = handshake_task,
                                    .ctx = provision,
                                });
                            },
                            .send => |buf| {
                                log.debug("requeing send in handshake", .{});
                                try rt.net.send(.{
                                    .socket = provision.socket,
                                    .buffer = buf,
                                    .func = handshake_task,
                                    .ctx = provision,
                                });
                            },
                            .complete => {
                                log.debug("handshake complete", .{});
                                provision.job = .{ .recv = .{ .count = 0 } };
                                try rt.net.recv(.{
                                    .socket = provision.socket,
                                    .buffer = provision.buffer,
                                    .func = recv_task,
                                    .ctx = provision,
                                });
                            },
                        }
                    },
                }
            } else unreachable;
        }

        fn send_task(rt: *Runtime, t: *const Task, ctx: ?*anyopaque) !void {
            const provision: *Provision = @ptrCast(@alignCast(ctx.?));
            assert(provision.job == .send);
            const length: i32 = t.result.?.value;

            const z_config: *const zzzConfig = @ptrCast(@alignCast(rt.storage.get("z_config").?));

            // If the socket is closed.
            if (length <= 0) {
                provision.job = .close;
                try rt.net.close(.{
                    .fd = provision.socket,
                    .func = close_task,
                    .ctx = provision,
                });
                return;
            }

            const send_job = &provision.job.send;

            log.debug("{d} - send triggered", .{provision.index});
            const send_count: usize = @intCast(length);
            log.debug("{d} - send length: {d}", .{ provision.index, send_count });

            switch (comptime security) {
                .tls => {
                    assert(send_job.security == .tls);

                    const tls_slice: []TLSType = @as(
                        [*]TLSType,
                        @ptrCast(@alignCast(rt.storage.get("tls_slice").?)),
                    )[0..z_config.size_connections_max];

                    const job_tls = &send_job.security.tls;
                    job_tls.encrypted_count += send_count;

                    if (job_tls.encrypted_count >= job_tls.encrypted.len) {
                        if (send_job.count >= send_job.slice.len) {
                            // All done sending.
                            log.debug("{d} - queueing a new recv", .{provision.index});
                            _ = provision.arena.reset(.{
                                .retain_with_limit = z_config.size_connection_arena_retain,
                            });
                            provision.recv_buffer.clearRetainingCapacity();
                            provision.job = .{ .recv = .{ .count = 0 } };

                            try rt.net.recv(.{
                                .socket = provision.socket,
                                .buffer = provision.buffer,
                                .func = recv_task,
                                .ctx = provision,
                            });
                        } else {
                            // Queue a new chunk up for sending.
                            log.debug(
                                "{d} - sending next chunk starting at index {d}",
                                .{ provision.index, send_job.count },
                            );

                            const inner_slice = send_job.slice.get(
                                send_job.count,
                                send_job.count + z_config.size_socket_buffer,
                            );

                            send_job.count += @intCast(inner_slice.len);

                            const tls_ptr: *?TLS = &tls_slice[provision.index];
                            assert(tls_ptr.* != null);

                            const encrypted = tls_ptr.*.?.encrypt(inner_slice) catch |e| {
                                log.err("{d} - encrypt failed: {any}", .{ provision.index, e });
                                provision.job = .close;
                                try rt.net.close(.{
                                    .fd = provision.socket,
                                    .func = close_task,
                                    .ctx = provision,
                                });
                                return error.TLSEncryptFailed;
                            };

                            job_tls.encrypted = encrypted;
                            job_tls.encrypted_count = 0;

                            try rt.net.send(.{
                                .socket = provision.socket,
                                .buffer = job_tls.encrypted,
                                .func = send_task,
                                .ctx = provision,
                            });
                        }
                    } else {
                        log.debug(
                            "{d} - sending next encrypted chunk starting at index {d}",
                            .{ provision.index, job_tls.encrypted_count },
                        );

                        const remainder = job_tls.encrypted[job_tls.encrypted_count..];
                        try rt.net.send(.{
                            .socket = provision.socket,
                            .buffer = remainder,
                            .func = send_task,
                            .ctx = provision,
                        });
                    }
                },
                .plain => {
                    assert(send_job.security == .plain);
                    send_job.count += send_count;

                    if (send_job.count >= send_job.slice.len) {
                        log.debug("{d} - queueing a new recv", .{provision.index});
                        _ = provision.arena.reset(.{
                            .retain_with_limit = z_config.size_connection_arena_retain,
                        });
                        provision.recv_buffer.clearRetainingCapacity();
                        provision.job = .{ .recv = .{ .count = 0 } };

                        try rt.net.recv(.{
                            .socket = provision.socket,
                            .buffer = provision.buffer,
                            .func = recv_task,
                            .ctx = provision,
                        });
                    } else {
                        log.debug(
                            "{d} - sending next chunk starting at index {d}",
                            .{ provision.index, send_job.count },
                        );

                        const plain_buffer = send_job.slice.get(
                            send_job.count,
                            send_job.count + z_config.size_socket_buffer,
                        );

                        log.debug("{d} - chunk ends at: {d}", .{
                            provision.index,
                            plain_buffer.len + send_job.count,
                        });

                        try rt.net.send(.{
                            .socket = provision.socket,
                            .buffer = plain_buffer,
                            .func = send_task,
                            .ctx = provision,
                        });
                    }
                },
            }
        }

        pub fn listen(self: *Self, protocol_config: ProtocolConfig) !void {
            log.info("server listening...", .{});
            log.info("security mode: {s}", .{@tagName(security)});

            const EntryParams = struct {
                zzz: *const Self,
                p_config: *const ProtocolConfig,
            };

            try self.tardy.entry(
                struct {
                    fn rt_start(rt: *Runtime, alloc: std.mem.Allocator, params: EntryParams) !void {
                        const socket = try alloc.create(std.posix.socket_t);
                        socket.* = try params.zzz.create_socket();
                        try std.posix.listen(socket.*, params.zzz.config.size_backlog);

                        // use the arena here.
                        var pool_params = params.zzz.config;
                        pool_params.allocator = alloc;

                        const provision_pool = try alloc.create(Pool(Provision));
                        provision_pool.* = try Pool(Provision).init(
                            alloc,
                            params.zzz.config.size_connections_max,
                            Provision.init_hook,
                            pool_params,
                        );

                        for (provision_pool.items) |*provision| {
                            provision.data = ProtocolData.init(alloc, params.p_config);
                        }

                        try rt.storage.put("provision_pool", provision_pool);
                        try rt.storage.put("z_config", @constCast(&params.zzz.config));
                        try rt.storage.put("p_config", @constCast(params.p_config));

                        if (comptime security == .tls) {
                            const tls_slice = try alloc.alloc(
                                TLSType,
                                params.zzz.config.size_connections_max,
                            );
                            if (comptime security == .tls) {
                                for (tls_slice) |*tls| {
                                    tls.* = null;
                                }
                            }
                            try rt.storage.put("tls_slice", tls_slice.ptr);
                            try rt.storage.put("tls_ctx", @constCast(&params.zzz.tls_ctx));
                        }

                        try rt.storage.put("server_socket", socket);

                        const accept_queued: *bool = try alloc.create(bool);
                        accept_queued.* = true;
                        try rt.storage.put("accept_queued", accept_queued);

                        try rt.net.accept(.{
                            .socket = socket.*,
                            .func = accept_task,
                        });
                    }
                }.rt_start,
                EntryParams{
                    .zzz = self,
                    .p_config = &protocol_config,
                },
                struct {
                    fn rt_end(rt: *Runtime, alloc: std.mem.Allocator, _: anytype) void {
                        // clean up socket.
                        const server_socket: *std.posix.socket_t = @ptrCast(@alignCast(rt.storage.get("server_socket").?));
                        std.posix.close(server_socket.*);
                        alloc.destroy(server_socket);

                        const accepted_queued: *bool = @ptrCast(@alignCast(rt.storage.get("accept_queued").?));
                        alloc.destroy(accepted_queued);

                        // clean up provision pool.
                        const provision_pool: *Pool(Provision) = @ptrCast(@alignCast(rt.storage.get("provision_pool").?));
                        for (provision_pool.items) |*provision| {
                            provision.data.deinit(alloc);
                        }
                        provision_pool.deinit(Provision.deinit_hook, alloc);
                        alloc.destroy(provision_pool);

                        // clean up TLS.
                        if (comptime security == .tls) {
                            const z_config: *const zzzConfig = @ptrCast(@alignCast(rt.storage.get("z_config").?));
                            const tls_slice: []TLSType = @as(
                                [*]TLSType,
                                @ptrCast(@alignCast(rt.storage.get("tls_slice").?)),
                            )[0..z_config.size_connections_max];
                            alloc.free(tls_slice);
                        }
                    }
                }.rt_end,
                void,
            );
        }
    };
}
