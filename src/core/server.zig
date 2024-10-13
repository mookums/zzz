const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/server");

const Pseudoslice = @import("pseudoslice.zig").Pseudoslice;
const Pool = @import("pool.zig").Pool;
const ZProvision = @import("zprovision.zig").ZProvision;

const TLSFileOptions = @import("../tls/lib.zig").TLSFileOptions;
const TLSContext = @import("../tls/lib.zig").TLSContext;
const TLS = @import("../tls/lib.zig").TLS;

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
    const Provision = ZProvision(ProtocolData);
    const Tardy = TardyCreator(async_type);

    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        tardy: Tardy,
        config: zzzConfig,
        socket: ?std.posix.socket_t = null,
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
                }) catch unreachable,
                .config = config,
                .socket = null,
                .tls_ctx = tls_ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            if (self.socket) |socket| {
                switch (comptime std.posix.socket_t) {
                    std.posix.socket_t => std.posix.close(socket),
                    else => unreachable,
                }
            }

            if (comptime security == .tls) {
                self.tls_ctx.deinit();
            }

            self.tardy.deinit();
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
            config: *const zzzConfig,
        ) void {
            defer provision_pool.release(provision.index);

            log.info("{d} - closing connection", .{provision.index});
            std.posix.close(provision.socket);
            switch (comptime builtin.target.os.tag) {
                .windows => {
                    provision.socket = std.os.windows.ws2_32.INVALID_SOCKET;
                },
                else => {
                    provision.socket = -1;
                },
            }
            provision.job = .empty;
            _ = provision.arena.reset(.{ .retain_with_limit = config.size_connection_arena_retain });
            provision.data.clean();
            provision.recv_buffer.clearRetainingCapacity();
        }

        //fn run(
        //    z_config: zzzConfig,
        //    p_config: ProtocolConfig,
        //    tls_ctx: TLSContextType,
        //    server_socket: std.posix.socket_t,
        //) !void {
        //    _ = tls_ctx;
        //    _ = server_socket;

        // Create and send the first Job.
        //var first_provision = Provision{
        //    .job = .accept,
        //    .index = std.math.maxInt(usize),
        //    .socket = undefined,
        //    .buffer = undefined,
        //    .recv_buffer = undefined,
        //    .arena = undefined,
        //    .data = undefined,
        //};

        //_ = try backend.queue_accept(
        //    &first_provision,
        //    server_socket,
        //);
        //try backend.submit();

        //var accept_queued = true;

        //while (true) {
        //    const completions = try backend.reap();
        //    const completions_count = completions.len;
        //    assert(completions_count > 0);
        //    log.debug("Completion Count: {d}", .{completions_count});

        //    reap_loop: for (completions[0..completions_count]) |completion| {
        //        const p: *Provision = @ptrCast(@alignCast(completion.context));

        //        switch (p.job) {
        //            .empty => continue :reap_loop,

        //            .accept => {
        //                accept_queued = false;
        //                const socket: std.posix.socket_t = completion.result.socket;

        //                switch (comptime builtin.target.os.tag) {
        //                    .windows => {
        //                        if (socket == std.os.windows.ws2_32.INVALID_SOCKET) {
        //                            log.err("socket accept failed", .{});
        //                            continue :reap_loop;
        //                        }
        //                    },
        //                    else => {
        //                        if (socket < 0) {
        //                            log.err("socket accept failed", .{});
        //                            continue :reap_loop;
        //                        }
        //                    },
        //                }

        //                // Borrow a provision from the pool otherwise close the socket.
        //                const borrowed = provision_pool.borrow() catch {
        //                    log.warn("out of provision pool entries", .{});
        //                    std.posix.close(socket);
        //                    continue :reap_loop;
        //                };

        //                log.info("{d} - accepting connection", .{borrowed.index});
        //                log.debug(
        //                    "empty provision slots: {d}",
        //                    .{provision_pool.items.len - provision_pool.dirty.count()},
        //                );
        //                assert(borrowed.item.job == .empty);

        //                switch (comptime std.posix.socket_t) {
        //                    std.posix.socket_t => {
        //                        // Disable Nagle's
        //                        if (comptime builtin.os.tag.isDarwin()) {
        //                            // system.TCP is weird on MacOS.
        //                            try std.posix.setsockopt(
        //                                socket,
        //                                std.posix.IPPROTO.TCP,
        //                                1,
        //                                &std.mem.toBytes(@as(c_int, 1)),
        //                            );
        //                        } else {
        //                            try std.posix.setsockopt(
        //                                socket,
        //                                std.posix.IPPROTO.TCP,
        //                                std.posix.TCP.NODELAY,
        //                                &std.mem.toBytes(@as(c_int, 1)),
        //                            );
        //                        }

        //                        // Set non-blocking.
        //                        switch (comptime builtin.target.os.tag) {
        //                            .windows => {
        //                                var mode: u32 = 1;
        //                                _ = std.os.windows.ws2_32.ioctlsocket(
        //                                    socket,
        //                                    std.os.windows.ws2_32.FIONBIO,
        //                                    &mode,
        //                                );
        //                            },
        //                            else => {
        //                                const current_flags = try std.posix.fcntl(socket, std.posix.F.GETFL, 0);
        //                                var new_flags = @as(
        //                                    std.posix.O,
        //                                    @bitCast(@as(u32, @intCast(current_flags))),
        //                                );
        //                                new_flags.NONBLOCK = true;
        //                                const arg: u32 = @bitCast(new_flags);
        //                                _ = try std.posix.fcntl(socket, std.posix.F.SETFL, arg);
        //                            },
        //                        }
        //                    },
        //                    else => unreachable,
        //                }

        //                const provision = borrowed.item;

        //                // Store the index of this item.
        //                provision.index = @intCast(borrowed.index);
        //                provision.socket = socket;

        //                var buffer: []u8 = provision.buffer;

        //                switch (comptime security) {
        //                    .tls => |_| {
        //                        const tls_ptr: *?TLS = &tls_pool[provision.index];
        //                        assert(tls_ptr.* == null);

        //                        tls_ptr.* = tls_ctx.create(socket) catch |e| {
        //                            log.err("{d} - tls creation failed={any}", .{ provision.index, e });
        //                            clean_connection(provision, &provision_pool, z_config);
        //                            continue :reap_loop;
        //                        };

        //                        const recv_buf = tls_ptr.*.?.start_handshake() catch |e| {
        //                            clean_tls(tls_ptr);
        //                            log.err("{d} - tls start handshake failed={any}", .{ provision.index, e });
        //                            clean_connection(provision, &provision_pool, z_config);
        //                            continue :reap_loop;
        //                        };

        //                        provision.job = .{ .handshake = .{ .state = .recv, .count = 0 } };
        //                        buffer = recv_buf;
        //                    },
        //                    .plain => {
        //                        provision.job = .{ .recv = .{ .count = 0 } };
        //                    },
        //                }

        //                // Call the Accept Hook.
        //                if (comptime accept_fn) |func| {
        //                    @call(.auto, func, .{ provision, p_config, z_config, backend });
        //                }

        //                _ = try backend.queue_recv(
        //                    provision,
        //                    provision.socket,
        //                    buffer,
        //                );
        //            },

        //            .handshake => |*inner| {
        //                assert(comptime security == .tls);
        //                if (comptime security == .tls) {
        //                    const tls_ptr: *?TLS = &tls_pool[p.index];
        //                    assert(tls_ptr.* != null);
        //                    log.debug("processing handshake", .{});
        //                    inner.count += 1;

        //                    if (completion.result.value < 0 or inner.count >= 50) {
        //                        clean_tls(tls_ptr);
        //                        clean_connection(p, &provision_pool, z_config);
        //                        continue :reap_loop;
        //                    }

        //                    const length: usize = @intCast(completion.result.value);

        //                    switch (inner.state) {
        //                        .recv => {
        //                            // on recv, we want to read from socket and feed into tls engien
        //                            const hstate = tls_ptr.*.?.continue_handshake(
        //                                .{ .recv = @intCast(length) },
        //                            ) catch |e| {
        //                                clean_tls(tls_ptr);
        //                                log.err("{d} - tls handshake on recv failed={any}", .{ p.index, e });
        //                                clean_connection(p, &provision_pool, z_config);
        //                                continue :reap_loop;
        //                            };

        //                            switch (hstate) {
        //                                .recv => |buf| {
        //                                    log.debug("requeing recv in handshake", .{});
        //                                    _ = try backend.queue_recv(
        //                                        p,
        //                                        p.socket,
        //                                        buf,
        //                                    );
        //                                },
        //                                .send => |buf| {
        //                                    log.debug("queueing send in handshake", .{});
        //                                    inner.state = .send;
        //                                    _ = try backend.queue_send(
        //                                        p,
        //                                        p.socket,
        //                                        buf,
        //                                    );
        //                                },
        //                                .complete => {
        //                                    log.debug("handshake complete", .{});
        //                                    p.job = .{ .recv = .{ .count = 0 } };
        //                                    _ = try backend.queue_recv(
        //                                        p,
        //                                        p.socket,
        //                                        p.buffer,
        //                                    );
        //                                },
        //                            }
        //                        },
        //                        .send => {
        //                            // on recv, we want to read from socket and feed into tls engien
        //                            const hstate = tls_ptr.*.?.continue_handshake(
        //                                .{ .send = @intCast(length) },
        //                            ) catch |e| {
        //                                clean_tls(tls_ptr);
        //                                log.err("{d} - tls handshake on send failed={any}", .{ p.index, e });
        //                                clean_connection(p, &provision_pool, z_config);
        //                                continue :reap_loop;
        //                            };

        //                            switch (hstate) {
        //                                .recv => |buf| {
        //                                    inner.state = .recv;
        //                                    log.debug("queuing recv in handshake", .{});
        //                                    _ = try backend.queue_recv(
        //                                        p,
        //                                        p.socket,
        //                                        buf,
        //                                    );
        //                                },
        //                                .send => |buf| {
        //                                    log.debug("requeing send in handshake", .{});
        //                                    _ = try backend.queue_send(
        //                                        p,
        //                                        p.socket,
        //                                        buf,
        //                                    );
        //                                },
        //                                .complete => {
        //                                    log.debug("handshake complete", .{});
        //                                    p.job = .{ .recv = .{ .count = 0 } };
        //                                    _ = try backend.queue_recv(
        //                                        p,
        //                                        p.socket,
        //                                        p.buffer,
        //                                    );
        //                                },
        //                            }
        //                        },
        //                    }
        //                } else unreachable;
        //            },

        //            .recv => |*inner| {
        //                log.debug("{d} - recv triggered", .{p.index});

        //                // If the socket is closed.
        //                if (completion.result.value <= 0) {
        //                    if (comptime security == .tls) {
        //                        const tls_ptr: *?TLS = &tls_pool[p.index];
        //                        clean_tls(tls_ptr);
        //                    }

        //                    clean_connection(p, &provision_pool, z_config);
        //                    continue :reap_loop;
        //                }

        //                const read_count: u32 = @intCast(completion.result.value);
        //                inner.count += read_count;
        //                const pre_recv_buffer = p.buffer[0..read_count];

        //                const recv_buffer = blk: {
        //                    switch (comptime security) {
        //                        .tls => |_| {
        //                            const tls_ptr: *?TLS = &tls_pool[p.index];
        //                            assert(tls_ptr.* != null);

        //                            break :blk tls_ptr.*.?.decrypt(pre_recv_buffer) catch |e| {
        //                                log.err("{d} - decrypt failed: {any}", .{ p.index, e });
        //                                clean_tls(tls_ptr);
        //                                clean_connection(p, &provision_pool, z_config);
        //                                continue :reap_loop;
        //                            };
        //                        },
        //                        .plain => break :blk pre_recv_buffer,
        //                    }
        //                };

        //                var status: RecvStatus = @call(.auto, recv_fn, .{
        //                    p,
        //                    p_config,
        //                    z_config,
        //                    backend,
        //                    recv_buffer,
        //                });

        //                switch (status) {
        //                    .kill => {
        //                        return;
        //                    },
        //                    .recv => {
        //                        try backend.queue_recv(
        //                            p,
        //                            p.socket,
        //                            p.buffer,
        //                        );
        //                    },
        //                    .send => |*pslice| {
        //                        const plain_buffer = pslice.get(0, z_config.size_socket_buffer);

        //                        switch (comptime security) {
        //                            .tls => |_| {
        //                                const tls_ptr: *?TLS = &tls_pool[p.index];
        //                                assert(tls_ptr.* != null);

        //                                const encrypted_buffer = tls_ptr.*.?.encrypt(plain_buffer) catch {
        //                                    clean_tls(tls_ptr);
        //                                    clean_connection(p, &provision_pool, z_config);
        //                                    continue :reap_loop;
        //                                };

        //                                p.job = .{
        //                                    .send = .{
        //                                        .tls = .{
        //                                            .slice = pslice.*,
        //                                            .count = @intCast(plain_buffer.len),
        //                                            .encrypted = encrypted_buffer,
        //                                            .encrypted_count = 0,
        //                                        },
        //                                    },
        //                                };

        //                                try backend.queue_send(
        //                                    p,
        //                                    p.socket,
        //                                    encrypted_buffer,
        //                                );
        //                            },
        //                            .plain => {
        //                                p.job = .{
        //                                    .send = .{
        //                                        .plain = .{
        //                                            .slice = pslice.*,
        //                                            .count = 0,
        //                                        },
        //                                    },
        //                                };
        //                                try backend.queue_send(
        //                                    p,
        //                                    p.socket,
        //                                    plain_buffer,
        //                                );
        //                            },
        //                        }
        //                    },
        //                }
        //            },

        //            .send => |*send_type| {
        //                log.debug("{d} - send triggered", .{p.index});
        //                const send_count = completion.result.value;
        //                log.debug("{d} - send length: {d}", .{ p.index, completion.result.value });

        //                if (send_count <= 0) {
        //                    if (comptime security == .tls) {
        //                        const tls_ptr: *?TLS = &tls_pool[p.index];
        //                        clean_tls(tls_ptr);
        //                    }

        //                    clean_connection(p, &provision_pool, z_config);
        //                    continue :reap_loop;
        //                }

        //                switch (comptime security) {
        //                    .tls => {
        //                        // This is for when sending encrypted data.
        //                        assert(send_type.* == .tls);

        //                        const inner = &send_type.tls;
        //                        inner.encrypted_count += @intCast(send_count);

        //                        if (inner.encrypted_count >= inner.encrypted.len) {
        //                            if (inner.count >= inner.slice.len) {
        //                                // All done sending.
        //                                log.debug("{d} - queueing a new recv", .{p.index});
        //                                _ = p.arena.reset(.{
        //                                    .retain_with_limit = z_config.size_connection_arena_retain,
        //                                });
        //                                p.recv_buffer.clearRetainingCapacity();
        //                                p.job = .{ .recv = .{ .count = 0 } };
        //                                try backend.queue_recv(
        //                                    p,
        //                                    p.socket,
        //                                    p.buffer,
        //                                );
        //                            } else {
        //                                // Queue a new chunk up for sending.
        //                                log.debug(
        //                                    "{d} - sending next chunk starting at index {d}",
        //                                    .{ p.index, inner.count },
        //                                );

        //                                const inner_slice = inner.slice.get(
        //                                    inner.count,
        //                                    inner.count + z_config.size_socket_buffer,
        //                                );

        //                                inner.count += @intCast(inner_slice.len);

        //                                const tls_ptr: *?TLS = &tls_pool[p.index];
        //                                assert(tls_ptr.* != null);

        //                                const encrypted = tls_ptr.*.?.encrypt(inner_slice) catch {
        //                                    clean_tls(tls_ptr);
        //                                    clean_connection(p, &provision_pool, z_config);
        //                                    continue :reap_loop;
        //                                };

        //                                inner.encrypted = encrypted;
        //                                inner.encrypted_count = 0;

        //                                try backend.queue_send(
        //                                    p,
        //                                    p.socket,
        //                                    inner.encrypted,
        //                                );
        //                            }
        //                        } else {
        //                            log.debug(
        //                                "{d} - sending next encrypted chunk starting at index {d}",
        //                                .{ p.index, inner.encrypted_count },
        //                            );

        //                            const remainder = inner.encrypted[inner.encrypted_count..];
        //                            try backend.queue_send(
        //                                p,
        //                                p.socket,
        //                                remainder,
        //                            );
        //                        }
        //                    },
        //                    .plain => {
        //                        // This is for when sending plaintext.
        //                        assert(send_type.* == .plain);

        //                        const inner = &send_type.plain;
        //                        inner.count += @intCast(send_count);

        //                        if (inner.count >= inner.slice.len) {
        //                            log.debug("{d} - queueing a new recv", .{p.index});
        //                            _ = p.arena.reset(.{
        //                                .retain_with_limit = z_config.size_connection_arena_retain,
        //                            });
        //                            p.recv_buffer.clearRetainingCapacity();
        //                            p.job = .{ .recv = .{ .count = 0 } };
        //                            try backend.queue_recv(
        //                                p,
        //                                p.socket,
        //                                p.buffer,
        //                            );
        //                        } else {
        //                            log.debug(
        //                                "{d} - sending next chunk starting at index {d}",
        //                                .{ p.index, inner.count },
        //                            );

        //                            const plain_buffer = inner.slice.get(
        //                                inner.count,
        //                                inner.count + z_config.size_socket_buffer,
        //                            );

        //                            log.debug("{d} - chunk ends at: {d}", .{
        //                                p.index,
        //                                plain_buffer.len + inner.count,
        //                            });

        //                            try backend.queue_send(
        //                                p,
        //                                p.socket,
        //                                plain_buffer,
        //                            );
        //                        }
        //                    },
        //                }
        //            },

        //            .close => {},

        //            else => @panic("not implemented yet!"),
        //        }
        //    }

        //    if (!accept_queued and !provision_pool.full()) {
        //        _ = try backend.queue_accept(&first_provision, server_socket);
        //        accept_queued = true;
        //    }

        //    try backend.submit();
        //}

        //unreachable;
        //}

        fn accept_predicate(rt: *Runtime, _: *Task) bool {
            const provision_pool: *Pool(Provision) = @ptrCast(@alignCast(rt.storage.get("provision_pool").?));
            const remaining = provision_pool.items.len - provision_pool.dirty.count();
            // We need atleast three because the new tasks and the underlying task.
            return remaining > 2;
        }

        fn accept_task(rt: *Runtime, t: *Task, ctx: ?*anyopaque) void {
            const server_socket: *std.posix.socket_t = @ptrCast(@alignCast(ctx.?));
            const child_socket = t.result.?.socket;

            // requeue the accept.
            rt.net.accept(.{
                .socket = server_socket.*,
                .func = accept_task,
                .ctx = server_socket,
                .predicate = accept_predicate,
            }) catch {
                rt.stop();
                return;
            };

            const pool: *Pool(Provision) = @ptrCast(@alignCast(rt.storage.get("provision_pool").?));

            switch (comptime builtin.target.os.tag) {
                .windows => {
                    if (child_socket == std.os.windows.ws2_32.INVALID_SOCKET) {
                        log.err("socket accept failed", .{});
                        return;
                    }
                },
                else => {
                    if (child_socket <= 0) {
                        log.err("socket accept failed", .{});
                        return;
                    }
                },
            }

            // Borrow a provision from the pool otherwise close the socket.
            const borrowed = pool.borrow_hint(t.index) catch {
                log.warn("out of provision pool entries", .{});
                std.posix.close(child_socket);
                return;
            };

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
                        std.posix.setsockopt(
                            child_socket,
                            std.posix.IPPROTO.TCP,
                            1,
                            &std.mem.toBytes(@as(c_int, 1)),
                        ) catch unreachable;
                    } else {
                        std.posix.setsockopt(
                            child_socket,
                            std.posix.IPPROTO.TCP,
                            std.posix.TCP.NODELAY,
                            &std.mem.toBytes(@as(c_int, 1)),
                        ) catch unreachable;
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
                            const current_flags = std.posix.fcntl(
                                child_socket,
                                std.posix.F.GETFL,
                                0,
                            ) catch unreachable;
                            var new_flags = @as(
                                std.posix.O,
                                @bitCast(@as(u32, @intCast(current_flags))),
                            );
                            new_flags.NONBLOCK = true;
                            const arg: u32 = @bitCast(new_flags);
                            _ = std.posix.fcntl(child_socket, std.posix.F.SETFL, arg) catch unreachable;
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
                    unreachable;
                    //const tls_ptr: *?TLS = &tls_pool[provision.index];
                    //assert(tls_ptr.* == null);

                    //tls_ptr.* = tls_ctx.create(child_socket) catch |e| {
                    //    log.err("{d} - tls creation failed={any}", .{ provision.index, e });
                    //    clean_connection(provision, &pool, z_config);
                    //    return;
                    //};

                    //const recv_buf = tls_ptr.*.?.start_handshake() catch |e| {
                    //    clean_tls(tls_ptr);
                    //    log.err("{d} - tls start handshake failed={any}", .{ provision.index, e });
                    //    clean_connection(provision, &pool, z_config);
                    //    return;
                    //};

                    //provision.job = .{ .handshake = .{ .state = .recv, .count = 0 } };
                    //buffer = recv_buf;
                },
                .plain => {
                    provision.job = .{ .recv = .{ .count = 0 } };
                },
            }

            rt.net.recv(.{
                .socket = child_socket,
                .buffer = provision.buffer,
                .func = recv_task,
                .ctx = borrowed.item,
            }) catch unreachable;
        }

        fn recv_task(rt: *Runtime, t: *Task, ctx: ?*anyopaque) void {
            const p: *Provision = @ptrCast(@alignCast(ctx.?));
            const length: i32 = t.result.?.value;

            const pool: *Pool(Provision) = @ptrCast(@alignCast(rt.storage.get("provision_pool").?));
            const p_config: *const ProtocolConfig = @ptrCast(@alignCast(rt.storage.get("p_config").?));
            const z_config: *const zzzConfig = @ptrCast(@alignCast(rt.storage.get("z_config").?));

            assert(p.job == .recv);
            const recv_job = &p.job.recv;

            // If the socket is closed.
            if (length <= 0) {
                // clean up
                if (comptime security == .tls) {
                    //const tls_ptr: *?TLS = &tls_pool[p.index];
                    //clean_tls(tls_ptr);
                }

                clean_connection(p, pool, z_config);
                return;
            }

            log.debug("{d} - recv triggered", .{p.index});

            const recv_count: u32 = @intCast(length);
            recv_job.count += recv_count;
            const pre_recv_buffer = p.buffer[0..recv_count];

            const recv_buffer = blk: {
                switch (comptime security) {
                    .tls => |_| {
                        unreachable;
                        //const tls_ptr: *?TLS = &tls_pool[p.index];
                        //assert(tls_ptr.* != null);

                        //break :blk tls_ptr.*.?.decrypt(pre_recv_buffer) catch |e| {
                        //    log.err("{d} - decrypt failed: {any}", .{ p.index, e });
                        //    clean_tls(tls_ptr);
                        //    clean_connection(p, &provision_pool, z_config);
                        //    continue :reap_loop;
                        //};
                    },
                    .plain => break :blk pre_recv_buffer,
                }
            };

            var status: RecvStatus = recv_fn(rt, p, p_config, z_config, recv_buffer);

            switch (status) {
                .kill => {
                    rt.stop();
                    return;
                },
                .recv => {
                    rt.net.recv(.{
                        .socket = p.socket,
                        .buffer = p.buffer,
                        .func = recv_task,
                        .ctx = ctx,
                    }) catch unreachable;
                },
                .send => |*pslice| {
                    const plain_buffer = pslice.get(0, z_config.size_socket_buffer);

                    switch (comptime security) {
                        .tls => |_| {
                            unreachable;
                            //const tls_ptr: *?TLS = &tls_pool[p.index];
                            //assert(tls_ptr.* != null);

                            //const encrypted_buffer = tls_ptr.*.?.encrypt(plain_buffer) catch {
                            //    clean_tls(tls_ptr);
                            //    clean_connection(p, &provision_pool, z_config);
                            //    continue :reap_loop;
                            //};

                            //p.job = .{
                            //    .send = .{
                            //        .tls = .{
                            //            .slice = pslice.*,
                            //            .count = @intCast(plain_buffer.len),
                            //            .encrypted = encrypted_buffer,
                            //            .encrypted_count = 0,
                            //        },
                            //    },
                            //};

                            //try backend.queue_send(
                            //    p,
                            //    p.socket,
                            //    encrypted_buffer,
                            //);
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

                            rt.net.send(.{
                                .socket = p.socket,
                                .buffer = plain_buffer,
                                .func = send_task,
                                .ctx = ctx,
                            }) catch unreachable;
                        },
                    }
                },
            }
        }

        fn send_task(rt: *Runtime, t: *Task, ctx: ?*anyopaque) void {
            const p: *Provision = @ptrCast(@alignCast(ctx.?));
            const length: i32 = t.result.?.value;

            const pool: *Pool(Provision) = @ptrCast(@alignCast(rt.storage.get("provision_pool").?));
            const z_config: *const zzzConfig = @ptrCast(@alignCast(rt.storage.get("z_config").?));

            // If the socket is closed.
            if (length <= 0) {
                // clean up
                if (comptime security == .tls) {
                    //const tls_ptr: *?TLS = &tls_pool[p.index];
                    //clean_tls(tls_ptr);
                }

                clean_connection(p, pool, z_config);
                return;
            }

            assert(p.job == .send);
            const send_job = &p.job.send;

            log.debug("{d} - send triggered", .{p.index});
            const send_count: u32 = @intCast(length);
            log.debug("{d} - send length: {d}", .{ p.index, send_count });

            switch (comptime security) {
                .tls => {
                    unreachable;
                    // This is for when sending encrypted data.
                    //assert(send_type.* == .tls);

                    //const inner = &send_type.tls;
                    //inner.encrypted_count += @intCast();

                    //if (inner.encrypted_count >= inner.encrypted.len) {
                    //    if (inner.count >= inner.slice.len) {
                    //        // All done sending.
                    //        log.debug("{d} - queueing a new recv", .{p.index});
                    //        _ = p.arena.reset(.{
                    //            .retain_with_limit = z_config.size_connection_arena_retain,
                    //        });
                    //        p.recv_buffer.clearRetainingCapacity();
                    //        p.job = .{ .recv = .{ .count = 0 } };
                    //        try backend.queue_recv(
                    //            p,
                    //            p.socket,
                    //            p.buffer,
                    //        );
                    //    } else {
                    //        // Queue a new chunk up for sending.
                    //        log.debug(
                    //            "{d} - sending next chunk starting at index {d}",
                    //            .{ p.index, inner.count },
                    //        );

                    //        const inner_slice = inner.slice.get(
                    //            inner.count,
                    //            inner.count + z_config.size_socket_buffer,
                    //        );

                    //        inner.count += @intCast(inner_slice.len);

                    //        const tls_ptr: *?TLS = &tls_pool[p.index];
                    //        assert(tls_ptr.* != null);

                    //        const encrypted = tls_ptr.*.?.encrypt(inner_slice) catch {
                    //            clean_tls(tls_ptr);
                    //            clean_connection(p, &provision_pool, z_config);
                    //            continue :reap_loop;
                    //        };

                    //        inner.encrypted = encrypted;
                    //        inner.encrypted_count = 0;

                    //        try backend.queue_send(
                    //            p,
                    //            p.socket,
                    //            inner.encrypted,
                    //        );
                    //    }
                    //} else {
                    //    log.debug(
                    //        "{d} - sending next encrypted chunk starting at index {d}",
                    //        .{ p.index, inner.encrypted_count },
                    //    );

                    //    const remainder = inner.encrypted[inner.encrypted_count..];
                    //    try backend.queue_send(
                    //        p,
                    //        p.socket,
                    //        remainder,
                    //    );
                    //}
                },
                .plain => {
                    // This is for when sending plaintext.
                    assert(send_job.* == .plain);

                    const inner = &send_job.plain;
                    inner.count += send_count;

                    if (inner.count >= inner.slice.len) {
                        log.debug("{d} - queueing a new recv", .{p.index});
                        _ = p.arena.reset(.{
                            .retain_with_limit = z_config.size_connection_arena_retain,
                        });
                        p.recv_buffer.clearRetainingCapacity();
                        p.job = .{ .recv = .{ .count = 0 } };

                        rt.net.recv(.{
                            .socket = p.socket,
                            .buffer = p.buffer,
                            .func = recv_task,
                            .ctx = ctx,
                        }) catch unreachable;
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

                        rt.net.send(.{
                            .socket = p.socket,
                            .buffer = plain_buffer,
                            .func = recv_task,
                            .ctx = ctx,
                        }) catch unreachable;
                    }
                },
            }
        }

        pub fn listen(self: *Self, protocol_config: ProtocolConfig) !void {
            assert(self.socket != null);
            const server_socket = self.socket.?;

            log.info("server listening...", .{});
            log.info("security mode: {s}", .{@tagName(security)});

            try std.posix.listen(server_socket, self.config.size_backlog);

            const EntryParams = struct {
                socket: *const std.posix.socket_t,
                z_config: *const zzzConfig,
                p_config: *const ProtocolConfig,
            };

            try self.tardy.entry(
                struct {
                    fn rt_start(rt: *Runtime, alloc: std.mem.Allocator, params: EntryParams) !void {
                        // this happens within each thread or runtime.
                        // this is where we need to do all of the initalization basically
                        //
                        // Creating everything we need to run for the foreseeable future.
                        const provision_pool = try alloc.create(Pool(Provision));
                        provision_pool.* = try Pool(Provision).init(
                            alloc,
                            params.z_config.size_connections_max,
                            Provision.init_hook,
                            params.z_config,
                        );

                        for (provision_pool.items) |*provision| {
                            provision.data = ProtocolData.init(alloc, params.p_config);
                        }

                        try rt.storage.put("provision_pool", provision_pool);
                        try rt.storage.put("z_config", @constCast(params.z_config));
                        try rt.storage.put("p_config", @constCast(params.p_config));

                        // If we don't have TLS set, this becomes 0 sized.
                        //const tls_pool = blk: {
                        //    switch (comptime security) {
                        //        .tls => |_| {
                        //            const pool = try alloc.alloc(?TLS, params.z_config.size_connections_max);
                        //            for (pool) |*tls| {
                        //                tls.* = null;
                        //            }

                        //            break :blk pool;
                        //        },
                        //        .plain => break :blk void{},
                        //    }
                        //};

                        try rt.net.accept(.{
                            .socket = params.socket.*,
                            .func = accept_task,
                            .ctx = @constCast(params.socket),
                            .predicate = accept_predicate,
                        });
                    }
                }.rt_start,
                EntryParams{
                    .socket = &server_socket,
                    .z_config = &self.config,
                    .p_config = &protocol_config,
                },
            );
        }
    };
}
