const std = @import("std");
const builtin = @import("builtin");
const tag = builtin.os.tag;
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/server");

const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;

const TLSFileOptions = @import("../tls/lib.zig").TLSFileOptions;
const TLSContext = @import("../tls/lib.zig").TLSContext;
const TLS = @import("../tls/lib.zig").TLS;

const _Context = @import("context.zig").Context;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Capture = @import("router/routing_trie.zig").Capture;
const QueryMap = @import("router/routing_trie.zig").QueryMap;
const ResponseSetOptions = Response.ResponseSetOptions;
const _SSE = @import("sse.zig").SSE;

const Provision = @import("provision.zig").Provision;
const Mime = @import("mime.zig").Mime;
const _Router = @import("router.zig").Router;
const _Route = @import("router/route.zig").Route;
const HTTPError = @import("lib.zig").HTTPError;

const AfterType = @import("../core/job.zig").AfterType;

const Pool = @import("tardy").Pool;
pub const Runtime = @import("tardy").Runtime;
pub const Task = @import("tardy").Task;
const TaskFn = @import("tardy").TaskFn;
pub const AsyncIOType = @import("tardy").AsyncIOType;
const TardyCreator = @import("tardy").Tardy;
const Cross = @import("tardy").Cross;

const AcceptResult = @import("tardy").AcceptResult;
const RecvResult = @import("tardy").RecvResult;
const SendResult = @import("tardy").SendResult;

pub const RecvStatus = union(enum) {
    kill,
    recv,
    send: Pseudoslice,
    spawned,
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

/// Uses the current p.response to generate and queue up the sending
/// of a response. This is used when we already know what we want to send.
///
/// See: `route_and_respond`
pub fn raw_respond(p: *Provision) !RecvStatus {
    {
        const status_code: u16 = if (p.response.status) |status| @intFromEnum(status) else 0;
        const status_name = if (p.response.status) |status| @tagName(status) else "No Status";
        log.info("{d} - {d} {s}", .{ p.index, status_code, status_name });
    }

    const body = p.response.body orelse "";
    const header_buffer = try p.response.headers_into_buffer(p.buffer, @intCast(body.len));
    p.response.headers.clear();
    const pseudo = Pseudoslice.init(header_buffer, body, p.buffer);
    return .{ .send = pseudo };
}

/// These are various general configuration
/// options that are important for the actual framework.
///
/// This includes various different options and limits
/// for interacting with the underlying network.
pub const ServerConfig = struct {
    /// Kernel Backlog Value.
    backlog_count: u31 = 512,
    /// Number of Maximum Concurrent Connections.
    ///
    /// This is applied PER runtime.
    /// zzz will drop/close any connections greater
    /// than this.
    ///
    /// You want to tune this to your expected number
    /// of maximum connections.
    ///
    /// Default: 1024
    connection_count_max: u16 = 1024,
    /// Maximum number of completions we can reap
    /// with a single call of reap().
    ///
    /// Default: 256
    completion_reap_max: u16 = 256,
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
    connection_arena_bytes_retain: u32 = 1024,
    /// Amount of space on the `recv_buffer` retained
    /// after every send.
    ///
    /// Default: 1KB
    list_recv_bytes_retain: u32 = 1024,
    /// Maximum size (in bytes) of the Recv buffer.
    /// This is mainly a concern when you are reading in
    /// large requests before responding.
    ///
    /// Default: 2MB.
    list_recv_bytes_max: u32 = 1024 * 1024 * 2,
    /// Size of the buffer (in bytes) used for
    /// interacting with the socket.
    ///
    /// Default: 1 KB.
    socket_buffer_bytes: u32 = 1024,
    /// Maximum number of Headers in a Request/Response
    ///
    /// Default: 32
    header_count_max: u16 = 32,
    /// Maximum number of Captures in a Route
    ///
    /// Default: 8
    capture_count_max: u16 = 8,
    /// Maximum number of Queries in a URL
    ///
    /// Default: 8
    query_count_max: u16 = 8,
    /// Maximum size (in bytes) of the Request.
    ///
    /// Default: 2MB.
    request_bytes_max: u32 = 1024 * 1024 * 2,
    /// Maximum size (in bytes) of the Request URI.
    ///
    /// Default: 2KB.
    request_uri_bytes_max: u32 = 1024 * 2,
};

pub fn Server(comptime security: Security, comptime AppState: type) type {
    const TLSContextType = comptime if (security == .tls) TLSContext else void;
    const TLSType = comptime if (security == .tls) ?TLS else void;

    return struct {
        const Self = @This();
        pub const Context = _Context(Self, AppState);
        pub const Router = _Router(Self, AppState);
        pub const Route = _Route(Self, AppState);
        pub const SSE = _SSE(Self, AppState);
        allocator: std.mem.Allocator,
        config: ServerConfig,
        addr: ?std.net.Address,
        tls_ctx: TLSContextType,
        router: *const Router,

        pub fn init(allocator: std.mem.Allocator, config: ServerConfig) Self {
            const tls_ctx = switch (comptime security) {
                .tls => |inner| TLSContext.init(allocator, .{
                    .cert = inner.cert,
                    .cert_name = inner.cert_name,
                    .key = inner.key,
                    .key_name = inner.key_name,
                    .size_tls_buffer_max = config.socket_buffer_bytes * 2,
                }) catch unreachable,
                .plain => void{},
            };

            return Self{
                .allocator = allocator,
                .config = config,
                .addr = null,
                .tls_ctx = tls_ctx,
                .router = undefined,
            };
        }

        pub fn deinit(self: *const Self) void {
            if (comptime security == .tls) {
                self.tls_ctx.deinit();
            }
        }

        const BindOptions = switch (builtin.os.tag) {
            // Currently, don't support unix sockets
            // on Windows.
            .windows => union(enum) {
                ip: struct { host: []const u8, port: u16 },
            },
            else => union(enum) {
                ip: struct { host: []const u8, port: u16 },
                unix: []const u8,
            },
        };

        pub fn bind(self: *Self, options: BindOptions) !void {
            self.addr = blk: {
                if (options == .ip) {
                    const inner = options.ip;
                    assert(inner.host.len > 0);
                    assert(inner.port > 0);

                    if (comptime builtin.os.tag == .linux) {
                        break :blk try std.net.Address.resolveIp(inner.host, inner.port);
                    } else {
                        break :blk try std.net.Address.parseIp(inner.host, inner.port);
                    }
                }

                if (comptime @hasField(BindOptions, "unix")) {
                    if (options == .unix) {
                        const path = options.unix;
                        assert(path.len > 0);

                        // Unlink the existing file if it exists.
                        _ = std.posix.unlink(path) catch |e| switch (e) {
                            error.FileNotFound => {},
                            else => return e,
                        };

                        break :blk try std.net.Address.initUnix(path);
                    }
                }

                unreachable;
            };
        }

        pub fn close_task(rt: *Runtime, _: void, provision: *Provision) !void {
            assert(provision.job == .close);
            const server_socket = rt.storage.get("__zzz_server_socket", std.posix.socket_t);
            const pool = rt.storage.get_ptr("__zzz_provision_pool", Pool(Provision));
            const config = rt.storage.get_const_ptr("__zzz_config", ServerConfig);

            log.info("{d} - closing connection", .{provision.index});

            if (comptime security == .tls) {
                const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);
                const tls_ptr: *TLSType = &tls_slice[provision.index];
                assert(tls_ptr.* != null);
                tls_ptr.*.?.deinit();
                tls_ptr.* = null;
            }

            provision.socket = Cross.socket.INVALID_SOCKET;
            provision.job = .empty;
            _ = provision.arena.reset(.{ .retain_with_limit = config.connection_arena_bytes_retain });

            provision.request.clear();
            provision.response.clear();

            if (provision.recv_buffer.len > config.list_recv_bytes_retain) {
                try provision.recv_buffer.shrink_clear_and_free(config.list_recv_bytes_retain);
            } else {
                provision.recv_buffer.clear_retaining_capacity();
            }

            pool.release(provision.index);

            const accept_queued = rt.storage.get_ptr("__zzz_accept_queued", bool);
            if (!accept_queued.*) {
                accept_queued.* = true;
                try rt.net.accept(
                    server_socket,
                    accept_task,
                    server_socket,
                );
            }
        }

        fn accept_task(rt: *Runtime, result: AcceptResult, socket: std.posix.socket_t) !void {
            const accept_queued = rt.storage.get_ptr("__zzz_accept_queued", bool);

            const child_socket = result.unwrap() catch |e| {
                log.err("socket accept failed | {}", .{e});
                accept_queued.* = true;
                try rt.net.accept(socket, accept_task, socket);
                return;
            };

            const pool = rt.storage.get_ptr("__zzz_provision_pool", Pool(Provision));
            accept_queued.* = false;

            if (rt.scheduler.tasks.clean() >= 2) {
                accept_queued.* = true;
                try rt.net.accept(socket, accept_task, socket);
            }

            // This should never fail. It means that we have a dangling item.
            assert(pool.clean() > 0);
            const borrowed = pool.borrow() catch unreachable;

            log.info("{d} - accepting connection", .{borrowed.index});
            log.debug(
                "empty provision slots: {d}",
                .{pool.items.len - pool.dirty.count()},
            );
            assert(borrowed.item.job == .empty);

            if (!rt.storage.get("__zzz_is_unix", bool))
                try Cross.socket.disable_nagle(child_socket);

            try Cross.socket.to_nonblock(child_socket);

            const provision = borrowed.item;

            // Store the index of this item.
            provision.index = @intCast(borrowed.index);
            provision.socket = child_socket;
            log.debug("provision buffer size: {d}", .{provision.buffer.len});

            switch (comptime security) {
                .tls => |_| {
                    const tls_ctx = rt.storage.get_const_ptr("__zzz_tls_ctx", TLSContextType);
                    const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);

                    const tls_ptr: *TLSType = &tls_slice[provision.index];
                    assert(tls_ptr.* == null);

                    tls_ptr.* = tls_ctx.create(child_socket) catch |e| {
                        log.err("{d} - tls creation failed={any}", .{ provision.index, e });
                        provision.job = .close;
                        try rt.net.close(provision, close_task, provision.socket);
                        return error.TLSCreationFailed;
                    };

                    const recv_buf = tls_ptr.*.?.start_handshake() catch |e| {
                        log.err("{d} - tls start handshake failed={any}", .{ provision.index, e });
                        provision.job = .close;
                        try rt.net.close(provision, close_task, provision.socket);
                        return error.TLSStartHandshakeFailed;
                    };

                    provision.job = .{ .handshake = .{ .state = .recv, .count = 0 } };
                    try rt.net.recv(borrowed.item, handshake_recv_task, child_socket, recv_buf);
                },
                .plain => {
                    provision.job = .{ .recv = .{ .count = 0 } };
                    try rt.net.recv(provision, recv_task, child_socket, provision.buffer);
                },
            }
        }

        fn recv_task(rt: *Runtime, result: RecvResult, provision: *Provision) !void {
            assert(provision.job == .recv);

            // recv_count is how many bytes we have read off the socket
            const recv_count = result.unwrap() catch |e| {
                if (e != error.Closed) {
                    log.warn("socket recv failed | {}", .{e});
                }
                provision.job = .close;
                try rt.net.close(provision, close_task, provision.socket);
                return;
            };

            const config = rt.storage.get_const_ptr("__zzz_config", ServerConfig);
            const router = rt.storage.get_const_ptr("__zzz_router", Router);

            const recv_job = &provision.job.recv;

            log.debug("{d} - recv triggered", .{provision.index});

            // this is how many http bytes we have received
            const http_bytes_count: usize = blk: {
                if (comptime security == .tls) {
                    const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);
                    const tls_ptr: *TLSType = &tls_slice[provision.index];
                    assert(tls_ptr.* != null);

                    const decrypted = tls_ptr.*.?.decrypt(provision.buffer[0..recv_count]) catch |e| {
                        log.err("{d} - decrypt failed: {any}", .{ provision.index, e });
                        provision.job = .close;
                        try rt.net.close(provision, close_task, provision.socket);
                        return error.TLSDecryptFailed;
                    };

                    // since we haven't marked the write yet, we can get a new write area
                    // that is directly adjacent to the last write block.
                    const area = try provision.recv_buffer.get_write_area(decrypted.len);
                    std.mem.copyForwards(u8, area, decrypted);
                    break :blk decrypted.len;
                } else {
                    break :blk recv_count;
                }
            };

            provision.recv_buffer.mark_written(http_bytes_count);
            provision.buffer = try provision.recv_buffer.get_write_area(config.socket_buffer_bytes);
            recv_job.count += http_bytes_count;

            const status = try on_recv(http_bytes_count, rt, provision, router, config);
            assert(provision.buffer.len == config.socket_buffer_bytes);

            switch (status) {
                .spawned => return,
                .kill => {
                    rt.stop();
                    return error.Killed;
                },
                .recv => {
                    try rt.net.recv(
                        provision,
                        recv_task,
                        provision.socket,
                        provision.buffer,
                    );
                },
                .send => |pslice| {
                    const first_buffer = try prepare_send(rt, provision, .recv, pslice);
                    try rt.net.send(
                        provision,
                        send_then_recv_task,
                        provision.socket,
                        first_buffer,
                    );
                },
            }
        }

        fn handshake_recv_task(rt: *Runtime, result: RecvResult, provision: *Provision) !void {
            assert(security == .tls);

            const length = result.unwrap() catch |e| {
                if (e != error.Closed) {
                    log.warn("socket recv failed | {}", .{e});
                }
                provision.job = .close;
                try rt.net.close(provision, close_task, provision.socket);
                return error.TLSHandshakeClosed;
            };

            try handshake_inner_task(rt, length, provision);
        }

        fn handshake_send_task(rt: *Runtime, result: SendResult, provision: *Provision) !void {
            assert(security == .tls);

            const length = result.unwrap() catch |e| {
                if (e != error.ConnectionReset) {
                    log.warn("socket send failed | {}", .{e});
                }
                provision.job = .close;
                try rt.net.close(provision, close_task, provision.socket);
                return error.TLSHandshakeClosed;
            };

            try handshake_inner_task(rt, length, provision);
        }

        fn handshake_inner_task(rt: *Runtime, length: usize, provision: *Provision) !void {
            assert(security == .tls);
            if (comptime security == .tls) {
                const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);

                assert(provision.job == .handshake);
                const handshake_job = &provision.job.handshake;

                const tls_ptr: *TLSType = &tls_slice[provision.index];
                assert(tls_ptr.* != null);
                log.debug("processing handshake", .{});
                handshake_job.count += 1;

                if (handshake_job.count >= 50) {
                    log.debug("handshake taken too many cycles", .{});
                    provision.job = .close;
                    try rt.net.close(provision, close_task, provision.socket);
                    return error.TLSHandshakeTooManyCycles;
                }

                const hstate = switch (handshake_job.state) {
                    .recv => tls_ptr.*.?.continue_handshake(.{ .recv = length }),
                    .send => tls_ptr.*.?.continue_handshake(.{ .send = length }),
                } catch |e| {
                    log.err("{d} - tls handshake failed={any}", .{ provision.index, e });
                    provision.job = .close;
                    try rt.net.close(provision, close_task, provision.socket);
                    return error.TLSHandshakeRecvFailed;
                };

                switch (hstate) {
                    .recv => |buf| {
                        log.debug("queueing recv in handshake", .{});
                        handshake_job.state = .recv;
                        try rt.net.recv(provision, handshake_recv_task, provision.socket, buf);
                    },
                    .send => |buf| {
                        log.debug("queueing send in handshake", .{});
                        handshake_job.state = .send;
                        try rt.net.send(provision, handshake_send_task, provision.socket, buf);
                    },
                    .complete => {
                        log.debug("handshake complete", .{});
                        provision.job = .{ .recv = .{ .count = 0 } };
                        try rt.net.recv(provision, recv_task, provision.socket, provision.buffer);
                    },
                }
            }
        }

        /// Prepares the provision send_job and returns the first send chunk
        pub fn prepare_send(rt: *Runtime, provision: *Provision, after: AfterType, pslice: Pseudoslice) ![]const u8 {
            const config = rt.storage.get_const_ptr("__zzz_config", ServerConfig);
            const plain_buffer = pslice.get(0, config.socket_buffer_bytes);

            switch (comptime security) {
                .tls => {
                    const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);
                    const tls_ptr: *TLSType = &tls_slice[provision.index];
                    assert(tls_ptr.* != null);

                    const encrypted_buffer = tls_ptr.*.?.encrypt(plain_buffer) catch |e| {
                        log.err("{d} - encrypt failed: {any}", .{ provision.index, e });
                        provision.job = .close;
                        try rt.net.close(provision, close_task, provision.socket);
                        return error.TLSEncryptFailed;
                    };

                    provision.job = .{
                        .send = .{
                            .after = after,
                            .slice = pslice,
                            .count = @intCast(plain_buffer.len),
                            .security = .{
                                .tls = .{
                                    .encrypted = encrypted_buffer,
                                    .encrypted_count = 0,
                                },
                            },
                        },
                    };

                    return encrypted_buffer;
                },
                .plain => {
                    provision.job = .{
                        .send = .{
                            .after = after,
                            .slice = pslice,
                            .count = 0,
                            .security = .plain,
                        },
                    };

                    return plain_buffer;
                },
            }
        }

        pub const send_then_other_task = send_then(struct {
            fn inner(rt: *Runtime, success: bool, provision: *Provision) !void {
                const send_job = provision.job.send;
                assert(send_job.after == .other);
                const func: TaskFn(bool, *anyopaque) = @ptrCast(@alignCast(send_job.after.other.func));
                const ctx: *anyopaque = @ptrCast(@alignCast(send_job.after.other.ctx));
                try @call(.auto, func, .{ rt, success, ctx });

                if (!success) {
                    provision.job = .close;
                    try rt.net.close(provision, close_task, provision.socket);
                }
            }
        }.inner);

        pub const send_then_recv_task = send_then(struct {
            fn inner(rt: *Runtime, success: bool, provision: *Provision) !void {
                if (!success) {
                    provision.job = .close;
                    try rt.net.close(provision, close_task, provision.socket);
                    return;
                }

                const config = rt.storage.get_const_ptr("__zzz_config", ServerConfig);

                log.debug("{d} - queueing a new recv", .{provision.index});
                _ = provision.arena.reset(.{
                    .retain_with_limit = config.connection_arena_bytes_retain,
                });

                provision.recv_buffer.clear_retaining_capacity();
                provision.job = .{ .recv = .{ .count = 0 } };
                provision.buffer = try provision.recv_buffer.get_write_area(config.socket_buffer_bytes);

                try rt.net.recv(
                    provision,
                    recv_task,
                    provision.socket,
                    provision.buffer,
                );
            }
        }.inner);

        pub fn send_then(comptime func: TaskFn(bool, *Provision)) TaskFn(SendResult, *Provision) {
            return struct {
                fn send_then_inner(rt: *Runtime, result: SendResult, provision: *Provision) !void {
                    assert(provision.job == .send);
                    const config = rt.storage.get_const_ptr("__zzz_config", ServerConfig);

                    const send_count = result.unwrap() catch |e| {
                        // If the socket is closed.
                        if (e != error.ConnectionReset) {
                            log.warn("socket send failed: {}", .{e});
                        }

                        try @call(.auto, func, .{ rt, false, provision });
                        return;
                    };

                    const send_job = &provision.job.send;

                    log.debug("{d} - send triggered", .{provision.index});
                    log.debug("{d} - sent length: {d}", .{ provision.index, send_count });

                    switch (comptime security) {
                        .tls => {
                            assert(send_job.security == .tls);

                            const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);

                            const job_tls = &send_job.security.tls;
                            job_tls.encrypted_count += send_count;

                            if (job_tls.encrypted_count >= job_tls.encrypted.len) {
                                if (send_job.count >= send_job.slice.len) {
                                    try @call(.auto, func, .{ rt, true, provision });
                                } else {
                                    // Queue a new chunk up for sending.
                                    log.debug(
                                        "{d} - sending next chunk starting at index {d}",
                                        .{ provision.index, send_job.count },
                                    );

                                    const inner_slice = send_job.slice.get(
                                        send_job.count,
                                        send_job.count + config.socket_buffer_bytes,
                                    );

                                    send_job.count += @intCast(inner_slice.len);

                                    const tls_ptr: *TLSType = &tls_slice[provision.index];
                                    assert(tls_ptr.* != null);

                                    const encrypted = tls_ptr.*.?.encrypt(inner_slice) catch |e| {
                                        log.err("{d} - encrypt failed: {any}", .{ provision.index, e });
                                        provision.job = .close;
                                        try rt.net.close(provision, close_task, provision.socket);
                                        return error.TLSEncryptFailed;
                                    };

                                    job_tls.encrypted = encrypted;
                                    job_tls.encrypted_count = 0;

                                    try rt.net.send(
                                        provision,
                                        send_then_inner,
                                        provision.socket,
                                        job_tls.encrypted,
                                    );
                                }
                            } else {
                                log.debug(
                                    "{d} - sending next encrypted chunk starting at index {d}",
                                    .{ provision.index, job_tls.encrypted_count },
                                );

                                const remainder = job_tls.encrypted[job_tls.encrypted_count..];
                                try rt.net.send(
                                    provision,
                                    send_then_inner,
                                    provision.socket,
                                    remainder,
                                );
                            }
                        },
                        .plain => {
                            assert(send_job.security == .plain);
                            send_job.count += send_count;

                            if (send_job.count >= send_job.slice.len) {
                                try @call(.auto, func, .{ rt, true, provision });
                            } else {
                                log.debug(
                                    "{d} - sending next chunk starting at index {d}",
                                    .{ provision.index, send_job.count },
                                );

                                const plain_buffer = send_job.slice.get(
                                    send_job.count,
                                    send_job.count + config.socket_buffer_bytes,
                                );

                                log.debug("socket buffer size: {d}", .{config.socket_buffer_bytes});

                                log.debug("{d} - chunk ends at: {d}", .{
                                    provision.index,
                                    plain_buffer.len + send_job.count,
                                });

                                // this is the problem.
                                // we are doing send then recv which is wrong!!
                                //
                                // we should be calling ourselves...
                                try rt.net.send(
                                    provision,
                                    send_then_inner,
                                    provision.socket,
                                    plain_buffer,
                                );
                            }
                        },
                    }
                }
            }.send_then_inner;
        }

        pub fn serve(self: *Self, router: *const Router, rt: *Runtime) !void {
            if (self.addr == null) return error.ServerNotBinded;
            const addr = self.addr.?;
            try rt.storage.store_alloc("__zzz_is_unix", addr.any.family == std.posix.AF.UNIX);

            self.router = router;

            log.info("server listening...", .{});
            log.info("security mode: {s}", .{@tagName(security)});

            const socket = try create_socket(addr);
            try std.posix.bind(socket, &addr.any, addr.getOsSockLen());
            try std.posix.listen(socket, self.config.backlog_count);

            const provision_pool = try rt.allocator.create(Pool(Provision));
            provision_pool.* = try Pool(Provision).init(
                rt.allocator,
                self.config.connection_count_max,
                Provision.InitContext{ .allocator = self.allocator, .config = self.config },
                Provision.init_hook,
            );

            try rt.storage.store_ptr("__zzz_router", @constCast(router));
            try rt.storage.store_ptr("__zzz_provision_pool", provision_pool);
            try rt.storage.store_alloc("__zzz_config", self.config);

            if (comptime security == .tls) {
                const tls_slice = try rt.allocator.alloc(
                    TLSType,
                    self.config.connection_count_max,
                );
                for (tls_slice) |*tls| {
                    tls.* = null;
                }

                // since slices are fat pointers...
                try rt.storage.store_alloc("__zzz_tls_slice", tls_slice);
                try rt.storage.store_alloc("__zzz_tls_ctx", self.tls_ctx);
            }

            try rt.storage.store_alloc("__zzz_server_socket", socket);
            try rt.storage.store_alloc("__zzz_accept_queued", true);

            try rt.net.accept(socket, accept_task, socket);
        }

        pub fn clean(rt: *Runtime) !void {
            // clean up socket.
            const server_socket = rt.storage.get("__zzz_server_socket", std.posix.socket_t);
            std.posix.close(server_socket);

            // clean up provision pool.
            const provision_pool = rt.storage.get_ptr("__zzz_provision_pool", Pool(Provision));
            provision_pool.deinit(rt.allocator, Provision.deinit_hook);
            rt.allocator.destroy(provision_pool);

            // clean up TLS.
            if (comptime security == .tls) {
                const tls_slice = rt.storage.get("__zzz_tls_slice", []TLSType);
                rt.allocator.free(tls_slice);
            }
        }

        fn create_socket(addr: std.net.Address) !std.posix.socket_t {
            const protocol: u32 = if (addr.any.family == std.posix.AF.UNIX)
                0
            else
                std.posix.IPPROTO.TCP;

            const socket = try std.posix.socket(
                addr.any.family,
                std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
                protocol,
            );

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

            return socket;
        }

        fn route_and_respond(runtime: *Runtime, p: *Provision, router: *const Router) !RecvStatus {
            route: {
                const found = try router.get_route_from_host(p.request.uri.?, p.captures, &p.queries);
                const optional_handler = found.route.get_handler(p.request.method.?);

                if (optional_handler) |handler| {
                    const context: *Context = try p.arena.allocator().create(Context);
                    context.* = .{
                        .allocator = p.arena.allocator(),
                        .runtime = runtime,
                        .state = router.state,
                        .route = &found.route,
                        .request = &p.request,
                        .response = &p.response,
                        .captures = found.captures,
                        .queries = found.queries,
                        .provision = p,
                    };

                    @call(.auto, handler, .{
                        context,
                    }) catch |e| {
                        log.err("\"{s}\" handler failed with error: {}", .{ p.request.uri.?, e });
                        p.response.set(.{
                            .status = .@"Internal Server Error",
                            .mime = Mime.HTML,
                            .body = "",
                        });

                        return try raw_respond(p);
                    };

                    return .spawned;
                } else {
                    // If we match the route but not the method.
                    p.response.set(.{
                        .status = .@"Method Not Allowed",
                        .mime = Mime.HTML,
                        .body = "405 Method Not Allowed",
                    });

                    // We also need to add to Allow header.
                    // This uses the connection's arena to allocate 64 bytes.
                    const allowed = found.route.get_allowed(p.arena.allocator()) catch {
                        p.response.set(.{
                            .status = .@"Internal Server Error",
                            .mime = Mime.HTML,
                            .body = "",
                        });

                        break :route;
                    };

                    p.response.headers.put_assume_capacity("Allow", allowed);
                    break :route;
                }
            }

            if (p.response.status == .Kill) {
                return .kill;
            }

            return try raw_respond(p);
        }

        fn on_recv(
            // How much we just received
            recv_count: usize,
            rt: *Runtime,
            provision: *Provision,
            router: *const Router,
            config: *const ServerConfig,
        ) !RecvStatus {
            var stage = provision.stage;
            const job = provision.job.recv;

            if (job.count >= config.request_bytes_max) {
                provision.response.set(.{
                    .status = .@"Content Too Large",
                    .mime = Mime.HTML,
                    .body = "Request was too large",
                });

                return try raw_respond(provision);
            }

            switch (stage) {
                .header => {
                    // this should never underflow if things are working correctly.
                    const starting_length = provision.recv_buffer.len - recv_count;
                    const start = starting_length -| 4;

                    const header_ends = std.mem.lastIndexOf(
                        u8,
                        provision.recv_buffer.subslice(.{ .start = start }),
                        "\r\n\r\n",
                    );

                    // Basically, this means we haven't finished processing the header.
                    if (header_ends == null) {
                        log.debug("{d} - header doesn't end in this chunk, continue", .{provision.index});
                        return .recv;
                    }

                    log.debug("{d} - parsing header", .{provision.index});
                    // We add start to account for the fact that we are searching
                    // starting at the index of start.
                    // The +4 is to account for the slice we match.
                    const header_end: usize = header_ends.? + start + 4;
                    provision.request.parse_headers(
                        provision.recv_buffer.subslice(.{ .end = header_end }),
                        .{
                            .request_bytes_max = config.request_bytes_max,
                            .request_uri_bytes_max = config.request_uri_bytes_max,
                        },
                    ) catch |e| {
                        switch (e) {
                            HTTPError.ContentTooLarge => {
                                provision.response.set(.{
                                    .status = .@"Content Too Large",
                                    .mime = Mime.HTML,
                                    .body = "Request was too large",
                                });
                            },
                            HTTPError.TooManyHeaders => {
                                provision.response.set(.{
                                    .status = .@"Request Header Fields Too Large",
                                    .mime = Mime.HTML,
                                    .body = "Too Many Headers",
                                });
                            },
                            HTTPError.MalformedRequest => {
                                provision.response.set(.{
                                    .status = .@"Bad Request",
                                    .mime = Mime.HTML,
                                    .body = "Malformed Request",
                                });
                            },
                            HTTPError.URITooLong => {
                                provision.response.set(.{
                                    .status = .@"URI Too Long",
                                    .mime = Mime.HTML,
                                    .body = "URI Too Long",
                                });
                            },
                            HTTPError.InvalidMethod => {
                                provision.response.set(.{
                                    .status = .@"Not Implemented",
                                    .mime = Mime.HTML,
                                    .body = "Not Implemented",
                                });
                            },
                            HTTPError.HTTPVersionNotSupported => {
                                provision.response.set(.{
                                    .status = .@"HTTP Version Not Supported",
                                    .mime = Mime.HTML,
                                    .body = "HTTP Version Not Supported",
                                });
                            },
                        }

                        return raw_respond(provision) catch unreachable;
                    };

                    // Logging information about Request.
                    log.info("{d} - \"{s} {s}\" {s}", .{
                        provision.index,
                        @tagName(provision.request.method.?),
                        provision.request.uri.?,
                        provision.request.headers.get("User-Agent") orelse "N/A",
                    });

                    // HTTP/1.1 REQUIRES a Host header to be present.
                    const is_http_1_1 = provision.request.version == .@"HTTP/1.1";
                    const is_host_present = provision.request.headers.get("Host") != null;
                    if (is_http_1_1 and !is_host_present) {
                        provision.response.set(.{
                            .status = .@"Bad Request",
                            .mime = Mime.HTML,
                            .body = "Missing \"Host\" Header",
                        });

                        return try raw_respond(provision);
                    }

                    if (!provision.request.expect_body()) {
                        return try route_and_respond(rt, provision, router);
                    }

                    // Everything after here is a Request that is expecting a body.
                    const content_length = blk: {
                        const length_string = provision.request.headers.get("Content-Length") orelse {
                            break :blk 0;
                        };

                        break :blk try std.fmt.parseInt(u32, length_string, 10);
                    };

                    if (header_end < provision.recv_buffer.len) {
                        const difference = provision.recv_buffer.len - header_end;
                        if (difference == content_length) {
                            // Whole Body
                            log.debug("{d} - got whole body with header", .{provision.index});
                            const body_end = header_end + difference;
                            provision.request.set(.{
                                .body = provision.recv_buffer.subslice(.{
                                    .start = header_end,
                                    .end = body_end,
                                }),
                            });
                            return try route_and_respond(rt, provision, router);
                        } else {
                            // Partial Body
                            log.debug("{d} - got partial body with header", .{provision.index});
                            stage = .{ .body = header_end };
                            return .recv;
                        }
                    } else if (header_end == provision.recv_buffer.len) {
                        // Body of length 0 probably or only got header.
                        if (content_length == 0) {
                            log.debug("{d} - got body of length 0", .{provision.index});
                            // Body of Length 0.
                            provision.request.set(.{ .body = "" });
                            return try route_and_respond(rt, provision, router);
                        } else {
                            // Got only header.
                            log.debug("{d} - got all header aka no body", .{provision.index});
                            stage = .{ .body = header_end };
                            return .recv;
                        }
                    } else unreachable;
                },

                .body => |header_end| {
                    // We should ONLY be here if we expect there to be a body.
                    assert(provision.request.expect_body());
                    log.debug("{d} - body matching", .{provision.index});

                    const content_length = blk: {
                        const length_string = provision.request.headers.get("Content-Length") orelse {
                            provision.response.set(.{
                                .status = .@"Length Required",
                                .mime = Mime.HTML,
                                .body = "",
                            });

                            return try raw_respond(provision);
                        };

                        break :blk try std.fmt.parseInt(u32, length_string, 10);
                    };

                    // We factor in the length of the headers.
                    const request_length = header_end + content_length;

                    // If this body will be too long, abort early.
                    if (request_length > config.request_bytes_max) {
                        provision.response.set(.{
                            .status = .@"Content Too Large",
                            .mime = Mime.HTML,
                            .body = "",
                        });
                        return try raw_respond(provision);
                    }

                    if (job.count >= request_length) {
                        provision.request.set(.{
                            .body = provision.recv_buffer.subslice(.{
                                .start = header_end,
                                .end = request_length,
                            }),
                        });
                        return try route_and_respond(rt, provision, router);
                    } else {
                        return .recv;
                    }
                },
            }
        }
    };
}
