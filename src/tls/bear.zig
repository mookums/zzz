const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/tls/bearssl");

const TLSFileOptions = @import("lib.zig").TLSFileOptions;

const bearssl = @cImport({
    @cInclude("bearssl.h");
});

const PrivateKey = union(enum) {
    RSA: bearssl.br_rsa_private_key,
    EC: bearssl.br_ec_private_key,
};

fn fmt_bearssl_error(error_code: c_int) []const u8 {
    return switch (error_code) {
        bearssl.BR_ERR_OK => "BR_ERR_OK",
        bearssl.BR_ERR_BAD_PARAM => "BR_ERR_BAD_PARAM",
        bearssl.BR_ERR_BAD_STATE => "BR_ERR_BAD_STATE",
        bearssl.BR_ERR_UNSUPPORTED_VERSION => "BR_ERR_UNSUPPORTED_VERSION",
        bearssl.BR_ERR_BAD_VERSION => "BR_ERR_BAD_VERSION",
        bearssl.BR_ERR_TOO_LARGE => "BR_ERR_TOO_LARGE",
        bearssl.BR_ERR_BAD_MAC => "BR_ERR_BAD_MAC",
        bearssl.BR_ERR_NO_RANDOM => "BR_ERR_NO_RANDOM",
        bearssl.BR_ERR_UNKNOWN_TYPE => "BR_ERR_UNKNOWN_TYPE",
        bearssl.BR_ERR_UNEXPECTED => "BR_ERR_UNEXPECTED",
        bearssl.BR_ERR_BAD_CCS => "BR_ERR_BAD_CCS",
        bearssl.BR_ERR_BAD_ALERT => "BR_ERR_BAD_ALERT",
        bearssl.BR_ERR_BAD_HANDSHAKE => "BR_ERR_BAD_HANDSHAKE",
        bearssl.BR_ERR_OVERSIZED_ID => "BR_ERR_OVERSIZED_ID",
        bearssl.BR_ERR_BAD_CIPHER_SUITE => "BR_ERR_BAD_CIPHER_SUITE",
        bearssl.BR_ERR_BAD_COMPRESSION => "BR_ERR_BAD_COMPRESSION",
        bearssl.BR_ERR_BAD_FRAGLEN => "BR_ERR_BAD_FRAGLEN",
        bearssl.BR_ERR_BAD_SECRENEG => "BR_ERR_BAD_SECRENEG",
        bearssl.BR_ERR_EXTRA_EXTENSION => "BR_ERR_EXTRA_EXTENSION",
        bearssl.BR_ERR_BAD_SNI => "BR_ERR_BAD_SNI",
        bearssl.BR_ERR_BAD_HELLO_DONE => "BR_ERR_BAD_HELLO_DONE",
        bearssl.BR_ERR_LIMIT_EXCEEDED => "BR_ERR_LIMIT_EXCEEDED",
        bearssl.BR_ERR_BAD_FINISHED => "BR_ERR_BAD_FINISHED",
        bearssl.BR_ERR_RESUME_MISMATCH => "BR_ERR_RESUME_MISMATCH",
        bearssl.BR_ERR_INVALID_ALGORITHM => "BR_ERR_INVALID_ALGORITHM",
        bearssl.BR_ERR_BAD_SIGNATURE => "BR_ERR_BAD_SIGNATURE",
        bearssl.BR_ERR_WRONG_KEY_USAGE => "BR_ERR_WRONG_KEY_USAGE",
        bearssl.BR_ERR_NO_CLIENT_AUTH => "BR_ERR_NO_CLIENT_AUTH",
        bearssl.BR_ERR_IO => "BR_ERR_IO",
        bearssl.BR_ERR_RECV_FATAL_ALERT => "BR_ERR_RECV_FATAL_ALERT",
        bearssl.BR_ERR_SEND_FATAL_ALERT => "BR_ERR_SEND_FATAL_ALERT",
        else => "Unknown BearSSL Error",
    };
}

fn parse_pem(allocator: std.mem.Allocator, section: []const u8, buffer: []const u8) ![]const u8 {
    var p_ctx: bearssl.br_pem_decoder_context = undefined;
    bearssl.br_pem_decoder_init(&p_ctx);

    var decoded = std.ArrayList(u8).init(allocator);

    bearssl.br_pem_decoder_setdest(&p_ctx, struct {
        fn decoder_cb(ctx: ?*anyopaque, src: ?*const anyopaque, size: usize) callconv(.C) void {
            var list: *std.ArrayList(u8) = @ptrCast(@alignCast(ctx));
            const src_buffer: [*c]const u8 = @ptrCast(src.?);
            list.appendSlice(src_buffer[0..size]) catch unreachable;
        }
    }.decoder_cb, &decoded);

    var found = false;
    var written: usize = 0;
    while (written < buffer.len) {
        written += bearssl.br_pem_decoder_push(&p_ctx, buffer[written..].ptr, buffer.len - written);
        const event = bearssl.br_pem_decoder_event(&p_ctx);
        switch (event) {
            0, bearssl.BR_PEM_BEGIN_OBJ => {
                const name = bearssl.br_pem_decoder_name(&p_ctx);
                log.debug("Name: {s}", .{std.mem.span(name)});
                if (std.mem.eql(u8, std.mem.span(name), section)) {
                    found = true;
                    decoded.clearRetainingCapacity();
                }
            },
            bearssl.BR_PEM_END_OBJ => {
                if (found) {
                    return decoded.toOwnedSlice();
                }
            },
            bearssl.BR_PEM_ERROR => return error.PEMDecodeFailed,
            else => return error.PEMDecodeUnknownEvent,
        }
    }

    return error.PrivateKeyNotFound;
}

const TLSContextOptions = struct {
    allocator: std.mem.Allocator,
    cert: TLSFileOptions,
    cert_name: []const u8,
    key: TLSFileOptions,
    key_name: []const u8,
    size_tls_buffer_max: u32,
};

pub const TLSContext = struct {
    parent_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    x509: *bearssl.br_x509_certificate,
    pkey: PrivateKey,
    cert: []const u8,
    key: []const u8,

    /// This only needs to be called once and it should create all of the stuff needed.
    pub fn init(options: TLSContextOptions) !TLSContext {
        var self: TLSContext = undefined;
        self.parent_allocator = options.allocator;
        self.arena = std.heap.ArenaAllocator.init(options.allocator);
        self.allocator = self.arena.allocator();

        const cert_buf = blk: {
            switch (options.cert) {
                .buffer => |inner| break :blk inner,
                .file => |inner| {
                    break :blk try std.fs.cwd().readFileAlloc(
                        self.allocator,
                        inner.path,
                        inner.size_buffer_max,
                    );
                },
            }
        };

        const key_buf = blk: {
            switch (options.key) {
                .buffer => |inner| break :blk inner,
                .file => |inner| {
                    break :blk try std.fs.cwd().readFileAlloc(
                        self.allocator,
                        inner.path,
                        inner.size_buffer_max,
                    );
                },
            }
        };

        self.cert = try parse_pem(self.allocator, options.cert_name, cert_buf);

        var x_ctx: bearssl.br_x509_decoder_context = undefined;
        bearssl.br_x509_decoder_init(&x_ctx, null, null);
        bearssl.br_x509_decoder_push(&x_ctx, self.cert.ptr, self.cert.len);

        if (bearssl.br_x509_decoder_last_error(&x_ctx) != 0) {
            return error.CertificateDecodeFailed;
        }

        self.x509 = try self.allocator.create(bearssl.br_x509_certificate);
        self.x509.* = bearssl.br_x509_certificate{
            .data = @constCast(self.cert.ptr),
            .data_len = self.cert.len,
        };

        // Read Private Key.
        self.key = try parse_pem(self.allocator, options.key_name, key_buf);

        var sk_ctx: bearssl.br_skey_decoder_context = undefined;
        bearssl.br_skey_decoder_init(&sk_ctx);
        bearssl.br_skey_decoder_push(&sk_ctx, self.key.ptr, self.key.len);

        if (bearssl.br_skey_decoder_last_error(&sk_ctx) != 0) {
            return error.PrivateKeyDecodeFailed;
        }

        const key_type = bearssl.br_skey_decoder_key_type(&sk_ctx);

        switch (key_type) {
            bearssl.BR_KEYTYPE_RSA => {
                const key = bearssl.br_skey_decoder_get_rsa(&sk_ctx)[0];
                self.pkey = .{
                    .RSA = bearssl.br_rsa_private_key{
                        .p = (try self.allocator.dupe(u8, key.p[0..key.plen])).ptr,
                        .plen = key.plen,
                        .q = (try self.allocator.dupe(u8, key.q[0..key.qlen])).ptr,
                        .qlen = key.qlen,
                        .dp = (try self.allocator.dupe(u8, key.dp[0..key.dplen])).ptr,
                        .dplen = key.dplen,
                        .dq = (try self.allocator.dupe(u8, key.dq[0..key.dqlen])).ptr,
                        .dqlen = key.dqlen,
                        .iq = (try self.allocator.dupe(u8, key.iq[0..key.iqlen])).ptr,
                        .iqlen = key.iqlen,
                        .n_bitlen = key.n_bitlen,
                    },
                };
            },
            bearssl.BR_KEYTYPE_EC => {
                const key = bearssl.br_skey_decoder_get_ec(&sk_ctx)[0];
                self.pkey = .{
                    .EC = bearssl.br_ec_private_key{
                        .x = (try self.allocator.dupe(u8, key.x[0..key.xlen])).ptr,
                        .xlen = key.xlen,
                        .curve = key.curve,
                    },
                };
            },
            else => {
                return error.InvalidKeyType;
            },
        }

        return self;
    }

    pub fn create(self: TLSContext, socket: std.posix.socket_t) !TLS {
        var tls = TLS.init(.{
            .allocator = self.parent_allocator,
            .socket = socket,
            .context = undefined,
            .pkey = self.pkey,
            .chain = self.x509[0..1],
        });

        switch (self.pkey) {
            .RSA => |*inner| {
                bearssl.br_ssl_server_init_full_rsa(
                    &tls.context,
                    self.x509,
                    1,
                    inner,
                );
            },
            .EC => |*inner| {
                assert(inner.x != 0);
                assert(inner.curve != 0);
                assert(inner.xlen != 0);

                bearssl.br_ssl_server_init_full_ec(
                    &tls.context,
                    self.x509,
                    1,
                    bearssl.BR_KEYTYPE_EC,
                    inner,
                );
            },
        }

        if (bearssl.br_ssl_engine_last_error(&tls.context.eng) != 0) {
            return error.ServerInitializationFailed;
        }

        return tls;
    }

    pub fn deinit(self: TLSContext) void {
        self.arena.deinit();
    }
};

const PolicyContext = struct {
    vtable: *bearssl.br_ssl_server_policy_class,
    chain: []const bearssl.br_x509_certificate,
    pkey: PrivateKey,
};

const HashFunction = struct {
    name: []const u8,
    hclass: *const bearssl.br_hash_class,
    comment: []const u8,
};

const hash_functions = [_]HashFunction{
    HashFunction{ .name = "md5", .hclass = &bearssl.br_md5_vtable, .comment = "MD5" },
    HashFunction{ .name = "sha1", .hclass = &bearssl.br_sha1_vtable, .comment = "SHA-1" },
    HashFunction{ .name = "sha224", .hclass = &bearssl.br_sha224_vtable, .comment = "SHA-224" },
    HashFunction{ .name = "sha256", .hclass = &bearssl.br_sha256_vtable, .comment = "SHA-256" },
    HashFunction{ .name = "sha384", .hclass = &bearssl.br_sha384_vtable, .comment = "SHA-384" },
    HashFunction{ .name = "sha512", .hclass = &bearssl.br_sha512_vtable, .comment = "SHA-512" },
};

fn choose_hash(chashes: u32) u32 {
    var hash_id: u32 = 6;

    while (hash_id >= 2) : (hash_id -= 1) {
        if (((chashes >> @intCast(hash_id)) & 0x1) != 0) {
            return @intCast(hash_id);
        }
    }

    unreachable;
}

fn get_hash_impl(hash_id: c_uint) !*const bearssl.br_hash_class {
    for (hash_functions) |hash| {
        const id = (hash.hclass.desc >> bearssl.BR_HASHDESC_ID_OFF) & bearssl.BR_HASHDESC_ID_MASK;
        if (id == hash_id) {
            log.debug("using hash: {s}", .{hash.name});
            return hash.hclass;
        }
    }

    return error.HashNotSupported;
}

fn choose(
    pctx: [*c][*c]const bearssl.br_ssl_server_policy_class,
    ctx: [*c]const bearssl.br_ssl_server_context,
    choices: [*c]bearssl.br_ssl_server_choices,
) callconv(.C) c_int {
    // https://www.bearssl.org/apidoc/structbr__ssl__server__policy__class__.html
    const policy: *const PolicyContext = @ptrCast(@alignCast(pctx));

    var suite_num: usize = 0;
    const suites: [*c]const bearssl.br_suite_translated = bearssl.br_ssl_server_get_client_suites(ctx, &suite_num);

    const hashes: u32 = bearssl.br_ssl_server_get_client_hashes(ctx);

    var ok: bool = false;

    for (0..suite_num) |i| {
        const tt = suites[i][1];

        switch (tt >> 12) {
            bearssl.BR_SSLKEYX_RSA => {
                log.debug("Choosing BR_SSLKEYX_RSA", .{});
                switch (policy.pkey) {
                    .RSA => {
                        choices.*.cipher_suite = suites[i][0];
                        ok = true;
                        break;
                    },
                    else => continue,
                }
            },
            bearssl.BR_SSLKEYX_ECDHE_RSA => {
                log.debug("Choosing BR_SSLKEYX_ECDHE_RSA", .{});
                switch (policy.pkey) {
                    .RSA => {
                        choices.*.cipher_suite = suites[i][0];

                        if (bearssl.br_ssl_engine_get_version(&ctx.*.eng) < bearssl.BR_TLS12) {
                            choices.*.algo_id = 0xFF00;
                            log.debug("Algo ID: {X}", .{choices.*.algo_id});
                        } else {
                            const id = choose_hash(hashes);
                            choices.*.algo_id = 0xFF00 + id;
                            log.debug("Algo ID: {X}", .{choices.*.algo_id});
                        }

                        // goto ok
                        ok = true;
                        break;
                    },
                    else => continue,
                }
            },

            bearssl.BR_SSLKEYX_ECDHE_ECDSA => {
                log.debug("Choosing BR_SSLKEYX_ECDHE_ECDSA", .{});
                switch (policy.pkey) {
                    .EC => {
                        choices.*.cipher_suite = suites[i][0];

                        if (bearssl.br_ssl_engine_get_version(&ctx.*.eng) < bearssl.BR_TLS12) {
                            choices.*.algo_id = 0xFF00 + bearssl.br_sha1_ID;
                        } else {
                            const id = choose_hash(hashes >> 8);
                            choices.*.algo_id = 0xFF00 + id;
                        }

                        ok = true;
                        break;
                    },
                    else => continue,
                }
            },

            bearssl.BR_SSLKEYX_ECDH_RSA => {
                log.debug("Choosing BR_SSLKEYX_ECDH_RSA", .{});
                switch (policy.pkey) {
                    .RSA => {
                        choices.*.cipher_suite = suites[i][0];
                        if (bearssl.br_ssl_engine_get_version(&ctx.*.eng) < bearssl.BR_TLS12) {
                            choices.*.algo_id = 0xFF00;
                            log.debug("Algo ID: {X}", .{choices.*.algo_id});
                        } else {
                            const id = choose_hash(hashes);
                            choices.*.algo_id = 0xFF00 + id;
                            log.debug("Algo ID: {X}", .{choices.*.algo_id});
                        }
                        ok = true;
                        break;
                    },
                    else => continue,
                }
            },
            bearssl.BR_SSLKEYX_ECDH_ECDSA => {
                log.debug("Choosing BR_SSLKEYX_ECDH_ECDSA", .{});
                switch (policy.pkey) {
                    .EC => {
                        choices.*.cipher_suite = suites[i][0];
                        if (bearssl.br_ssl_engine_get_version(&ctx.*.eng) < bearssl.BR_TLS12) {
                            choices.*.algo_id = 0xFF00 + bearssl.br_sha1_ID;
                        } else {
                            const id = choose_hash(hashes >> 8);
                            choices.*.algo_id = 0xFF00 + id;
                        }
                        ok = true;
                        break;
                    },
                    else => continue,
                }
            },
            else => {
                log.debug("Unknown Client Suite: {d}", .{tt >> 12});
                return 0;
            },
        }
    }

    if (ok) {
        // This is the good path.
        choices.*.chain = policy.chain.ptr;
        choices.*.chain_len = policy.chain.len;
        return 1;
    } else {
        return 0;
    }
}

fn do_keyx(
    pctx: [*c][*c]const bearssl.br_ssl_server_policy_class,
    data: [*c]u8,
    len: [*c]usize,
) callconv(.C) u32 {
    const policy: *const PolicyContext = @ptrCast(@alignCast(pctx));
    _ = policy;
    _ = data;
    _ = len;

    return 0;
}

fn do_sign(
    pctx: [*c][*c]const bearssl.br_ssl_server_policy_class,
    algo_id: c_uint,
    data: [*c]u8,
    hv_len: usize,
    len: usize,
) callconv(.C) usize {
    const policy: *const PolicyContext = @ptrCast(@alignCast(pctx));

    var hv: [64]u8 = undefined;
    var algo_inner_id = algo_id;

    if (algo_inner_id >= 0xFF00) {
        algo_inner_id &= 0xFF;
        std.mem.copyForwards(u8, &hv, data[0..hv_len]);
    }

    var sig_len: usize = 0;
    switch (policy.pkey) {
        .RSA => |*inner| {
            const class = get_hash_impl(algo_inner_id) catch {
                log.err("unsupported hash function {d}", .{algo_inner_id});
                return 0;
            };

            if (len < inner.n_bitlen / 8) {
                log.err("dailed to rsa-sign, buffer to small for len={d} for {d}-bit key", .{ len, inner.n_bitlen });
                return 0;
            }

            // PKCS#1 v1.5 padding
            sig_len = bearssl.br_rsa_pkcs1_sign_get_default().?(
                class,
                &hv,
                hv_len,
                inner,
                data,
            );

            if (sig_len == 0) {
                log.err("failed to rsa-sign, sig_len=0", .{});
                return 0;
            }

            return sig_len;
        },

        .EC => |*inner| {
            const class = get_hash_impl(algo_inner_id) catch {
                log.err("unsupported hash function {d}", .{algo_inner_id});
                return 0;
            };

            if (len < 139) {
                log.err("failed to ecdsa-sign, wrong len={d}", .{len});
                return 0;
            }

            sig_len = bearssl.br_ecdsa_sign_asn1_get_default().?(
                bearssl.br_ec_get_default(),
                class,
                &hv,
                inner,
                data,
            );

            if (sig_len == 0) {
                log.err("failed to ecdsa-sign, sig_len=0", .{});
                return 0;
            }

            return sig_len;
        },
    }

    return 0;
}

const TLSOptions = struct {
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    context: bearssl.br_ssl_server_context,
    chain: []const bearssl.br_x509_certificate,
    pkey: PrivateKey,
};

const policy_vtable = bearssl.br_ssl_server_policy_class{
    .context_size = @sizeOf(PolicyContext),
    .choose = choose,
    .do_keyx = do_keyx,
    .do_sign = do_sign,
};

pub const TLS = struct {
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    context: bearssl.br_ssl_server_context,
    iobuf: []u8,
    buffer: std.ArrayList(u8),
    // chain is not owned, we are just using the ref from tlsctx.
    chain: []const bearssl.br_x509_certificate,
    pkey: PrivateKey,
    policy: *PolicyContext,

    pub fn init(options: TLSOptions) TLS {
        return .{
            .allocator = options.allocator,
            .socket = options.socket,
            .context = options.context,
            .iobuf = options.allocator.alloc(u8, bearssl.BR_SSL_BUFSIZE_BIDI) catch unreachable,
            .buffer = std.ArrayList(u8).init(options.allocator),
            .chain = options.chain,
            .pkey = options.pkey,
            .policy = options.allocator.create(PolicyContext) catch unreachable,
        };
    }

    pub fn deinit(self: TLS) void {
        self.allocator.free(self.iobuf);
        self.allocator.destroy(self.policy);
        self.buffer.deinit();
    }

    // This will initalize the handshake and returns the first buffer to queue a recv into.
    pub fn start_handshake(self: *TLS) ![]u8 {
        const engine = &self.context.eng;
        bearssl.br_ssl_engine_set_buffer(engine, self.iobuf.ptr, self.iobuf.len, 1);

        // Build the Policy.
        self.policy.vtable = @constCast(&policy_vtable);
        self.policy.chain = self.chain;
        self.policy.pkey = self.pkey;

        bearssl.br_ssl_server_set_policy(&self.context, @ptrCast(&self.policy.vtable));

        const reset_status = bearssl.br_ssl_server_reset(&self.context);
        if (reset_status <= 0) {
            return error.ServerResetFailed;
        }
        const last_error = bearssl.br_ssl_engine_last_error(engine);
        if (last_error != 0) {
            log.debug("handshake failed | {s}", .{
                fmt_bearssl_error(last_error),
            });
            return error.HandshakeFailed;
        }

        const state = bearssl.br_ssl_engine_current_state(engine);

        if ((state & bearssl.BR_SSL_CLOSED) != 0) {
            return error.HandshakeFailed;
        }

        if ((state & bearssl.BR_SSL_SENDAPP) != 0) {
            return error.UnexpectedState;
        }

        if ((state & bearssl.BR_SSL_RECVAPP) != 0) {
            return error.UnexpectedState;
        }

        if ((state & bearssl.BR_SSL_SENDREC) != 0) {
            return error.UnexpectedState;
        }

        var length: usize = undefined;
        const buf = bearssl.br_ssl_engine_recvrec_buf(engine, &length);
        return buf[0..length];
    }

    pub const HandshakeInput = union(enum) {
        // this is the length of the recv to ack.
        recv: u32,
        // this is the length of the send to ack.
        send: u32,
    };

    const HandshakeState = union(enum) {
        // this is the buffer we want to queue_recv into.
        recv: []u8,
        // this is the buffer we want to queue_send from.
        send: []u8,
        // this is when we get to escape.
        complete,
    };

    // each step of the handshake goes through this func
    pub fn continue_handshake(self: *TLS, input: HandshakeInput) !HandshakeState {
        const engine = &self.context.eng;
        const last_error = bearssl.br_ssl_engine_last_error(engine);
        if (last_error != 0) {
            log.debug("handshake failed | {s}", .{
                fmt_bearssl_error(last_error),
            });
            return error.HandshakeFailed;
        }

        const state = bearssl.br_ssl_engine_current_state(engine);

        if ((state & bearssl.BR_SSL_CLOSED) != 0) {
            return error.HandshakeFailed;
        }

        if ((state & bearssl.BR_SSL_SENDAPP) != 0) {
            return error.UnexpectedState;
        }

        if ((state & bearssl.BR_SSL_RECVAPP) != 0) {
            return error.UnexpectedState;
        }

        switch (input) {
            .recv => |inner| {
                bearssl.br_ssl_engine_recvrec_ack(engine, inner);
            },
            .send => |inner| {
                bearssl.br_ssl_engine_sendrec_ack(engine, inner);
            },
        }

        const after_state = bearssl.br_ssl_engine_current_state(engine);
        const action: HandshakeState = blk: {
            if ((after_state & bearssl.BR_SSL_SENDAPP) != 0) break :blk .complete;

            if ((after_state & bearssl.BR_SSL_SENDREC) != 0) {
                var length: usize = 0;
                const buf = bearssl.br_ssl_engine_sendrec_buf(engine, &length);
                log.debug("send rec buffer: address={*}, length={d}", .{ buf, length });
                break :blk .{ .send = buf[0..length] };
            }

            if ((after_state & bearssl.BR_SSL_RECVREC) != 0) {
                var length: usize = 0;
                const buf = bearssl.br_ssl_engine_recvrec_buf(engine, &length);
                log.debug("recv rec buffer: address={*}, length={d}", .{ buf, length });
                break :blk .{ .recv = buf[0..length] };
            }

            return error.UnexpectedState;
        };

        log.debug("next action: {s}", .{@tagName(action)});
        return action;
    }

    pub fn decrypt(self: *TLS, encrypted: []const u8) ![]const u8 {
        self.buffer.clearRetainingCapacity();

        const engine = &self.context.eng;

        var recv_app = false;
        var encrypted_index: usize = 0;

        var cycle_count: u32 = 0;
        while (cycle_count < 50) : (cycle_count += 1) {
            const last_error = bearssl.br_ssl_engine_last_error(engine);
            log.debug("d cycle {d} - last error | {d}", .{ cycle_count, last_error });
            if (last_error != 0) {
                log.debug("d cycle {d} - decrypt failed | {s}", .{
                    cycle_count,
                    fmt_bearssl_error(last_error),
                });
                return error.DecryptFailed;
            }

            const state = bearssl.br_ssl_engine_current_state(engine);
            log.debug("d cycle {d} - engine state | {any}", .{ cycle_count, state });

            if ((state & bearssl.BR_SSL_CLOSED) != 0) {
                return error.DecryptFailed;
            }

            if ((state & bearssl.BR_SSL_RECVREC) != 0) {
                if (recv_app) {
                    return self.buffer.items;
                }

                log.debug("Triggered BR_SSL_RECVREC", .{});
                var length: usize = undefined;
                const buf = bearssl.br_ssl_engine_recvrec_buf(engine, &length);
                log.debug("d cycle {d} - recv rec buffer: address={*}, length={d}", .{ cycle_count, buf, length });
                if (length == 0) {
                    continue;
                }

                const min_length = @min(length, encrypted.len - encrypted_index);

                std.mem.copyForwards(
                    u8,
                    buf[0..min_length],
                    encrypted[encrypted_index .. encrypted_index + min_length],
                );
                encrypted_index += min_length;
                log.debug("d cycle {d} - total read: {d}", .{ cycle_count, min_length });
                bearssl.br_ssl_engine_recvrec_ack(engine, min_length);
                continue;
            }

            if ((state & bearssl.BR_SSL_RECVAPP) != 0) {
                recv_app = true;
                // Now we are reading out the decrypted data...
                log.debug("Triggered BR_SSL_RECVAPP", .{});
                var length: usize = undefined;
                const buf = bearssl.br_ssl_engine_recvapp_buf(engine, &length);
                log.debug("d cycle {d} - recv app buffer: address={*}, length={d}", .{ cycle_count, buf, length });

                if (length == 0) {
                    continue;
                }

                try self.buffer.appendSlice(buf[0..length]);
                log.debug("d cycle {d} - total read: {d}", .{ cycle_count, length });
                bearssl.br_ssl_engine_recvapp_ack(engine, length);
                continue;
            }

            if ((state & bearssl.BR_SSL_SENDAPP) != 0) {
                return error.SendAppWhy;
            }

            if ((state & bearssl.BR_SSL_SENDREC) != 0) {
                return error.SendRecWhy;
            }
        }

        return error.DecryptTimeout;
    }

    pub fn encrypt(self: *TLS, plaintext: []const u8) ![]const u8 {
        self.buffer.clearRetainingCapacity();

        const engine = &self.context.eng;

        var sent_rec = false;
        var plaintext_index: usize = 0;

        var cycle_count: u32 = 0;
        while (cycle_count < 50) : (cycle_count += 1) {
            const last_error = bearssl.br_ssl_engine_last_error(engine);
            log.debug("e cycle {d} - last error | {d}", .{ cycle_count, last_error });
            if (last_error != 0) {
                log.debug("e cycle {d} - encrypt failed | {s}", .{
                    cycle_count,
                    fmt_bearssl_error(last_error),
                });
                return error.DecryptFailed;
            }

            const state = bearssl.br_ssl_engine_current_state(engine);
            log.debug("e cycle {d} - engine state | {any}", .{ cycle_count, state });

            if ((state & bearssl.BR_SSL_CLOSED) != 0) {
                return error.DecryptFailed;
            }

            if ((state & bearssl.BR_SSL_SENDAPP) != 0) {
                log.debug("Triggered BR_SSL_SENDAPP", .{});

                if (sent_rec) {
                    return self.buffer.items;
                }

                var length: usize = undefined;
                const buf = bearssl.br_ssl_engine_sendapp_buf(engine, &length);

                log.debug("e cycle {d} - send app buffer: address={*}, length={d}", .{ cycle_count, buf, length });
                if (length == 0) {
                    continue;
                }

                const min_length = @min(length, plaintext.len - plaintext_index);

                std.mem.copyForwards(
                    u8,
                    buf[0..min_length],
                    plaintext[plaintext_index .. plaintext_index + min_length],
                );

                plaintext_index += min_length;
                log.debug("e cycle {d} - total send app: {d}", .{ cycle_count, min_length });
                bearssl.br_ssl_engine_sendapp_ack(engine, min_length);

                if (plaintext_index >= plaintext.len) {
                    // Force a record to be made.
                    bearssl.br_ssl_engine_flush(engine, 0);
                }

                continue;
            }

            if ((state & bearssl.BR_SSL_SENDREC) != 0) {
                sent_rec = true;
                log.debug("Triggered BR_SSL_SENDREC", .{});

                var length: usize = undefined;
                const buf = bearssl.br_ssl_engine_sendrec_buf(engine, &length);

                log.debug("e cycle {d} - send rec buffer: address={*}, length={d}", .{ cycle_count, buf, length });
                if (length == 0) {
                    continue;
                }

                try self.buffer.appendSlice(buf[0..length]);
                log.debug("e cycle {d} - total send rec: {d}", .{ cycle_count, length });
                bearssl.br_ssl_engine_sendrec_ack(engine, length);
                continue;
            }

            if ((state & bearssl.BR_SSL_RECVREC) != 0) {
                return error.RecvRecWhy;
            }

            if ((state & bearssl.BR_SSL_RECVAPP) != 0) {
                return error.RecvAppWhy;
            }
        }

        return error.EncryptTimeout;
    }
};

const testing = std.testing;

test "Parsing Certificates" {
    const cert = "src/examples/tls/certs/server.cert";
    const key = "src/examples/tls/certs/server.key";

    const context = try TLSContext.init(testing.allocator, cert, key);
    defer context.deinit();

    const tls = try context.create(undefined);
    defer tls.deinit();
}
