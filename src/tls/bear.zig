const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/tls/bearssl");

const Socket = @import("../core/socket.zig").Socket;

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
    cert_path: []const u8,
    key_path: []const u8,
    cert_name: []const u8,
    key_name: []const u8,
    size_tls_buffer_max: u32,
};

pub const TLSContext = struct {
    allocator: std.mem.Allocator,
    x509: *bearssl.br_x509_certificate,
    pkey: PrivateKey,
    cert: []const u8,
    key: []const u8,

    /// This only needs to be called once and it should create all of the stuff needed.
    pub fn init(options: TLSContextOptions) !TLSContext {
        var self: TLSContext = undefined;
        self.allocator = options.allocator;

        // Read Certificate.
        const cert_buf = try std.fs.cwd().readFileAlloc(
            self.allocator,
            options.cert_path,
            1024 * 1024,
        );
        defer self.allocator.free(cert_buf);

        const key_buf = try std.fs.cwd().readFileAlloc(
            self.allocator,
            options.key_path,
            1024 * 1024,
        );
        defer self.allocator.free(key_buf);

        self.cert = try parse_pem(self.allocator, options.cert_name, cert_buf);

        var x_ctx: bearssl.br_x509_decoder_context = undefined;
        bearssl.br_x509_decoder_init(&x_ctx, null, null);
        bearssl.br_x509_decoder_push(&x_ctx, self.cert.ptr, self.cert.len);

        if (bearssl.br_x509_decoder_last_error(&x_ctx) != 0) {
            return error.CertificateDecodeFailed;
        }

        self.x509 = try options.allocator.create(bearssl.br_x509_certificate);
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
                self.pkey = .{ .RSA = bearssl.br_skey_decoder_get_rsa(&sk_ctx)[0] };
            },
            bearssl.BR_KEYTYPE_EC => {
                const key = bearssl.br_skey_decoder_get_ec(&sk_ctx)[0];
                self.pkey = .{
                    .EC = bearssl.br_ec_private_key{
                        // TODO: This leaks right now, needs to be fixed.
                        .x = (try options.allocator.dupe(u8, std.mem.span(key.x))).ptr,
                        .xlen = key.xlen,
                        .curve = key.curve,
                    },
                };
                log.debug("Key Curve Type: {d}", .{self.pkey.EC.curve});
                log.debug("Key X: {x}", .{std.mem.span(self.pkey.EC.x)});
            },
            else => {
                return error.InvalidKeyType;
            },
        }

        return self;
    }

    pub fn create(self: TLSContext, socket: Socket) !TLS {
        var tls = TLS.init(.{
            .allocator = self.allocator,
            .socket = socket,
            .context = undefined,
            .pkey = self.pkey,
            .chain = self.x509[0..1],
        });

        log.debug("Self Key X: {x}", .{std.mem.span(self.pkey.EC.x)});
        log.debug("TLS Key X: {x}", .{std.mem.span(tls.pkey.EC.x)});

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
        self.allocator.free(self.cert);
        self.allocator.free(self.key);
        self.allocator.destroy(self.x509);
    }
};

const PolicyContext = struct {
    vtable: *bearssl.br_ssl_server_policy_class,
    // TODO: this isn't needed.
    id: u32 = 0,
    chain: []const bearssl.br_x509_certificate,
    pkey: PrivateKey,
};

const HashFunction = struct {
    name: []const u8,
    hclass: *const bearssl.br_hash_class,
    comment: []const u8,
};

const hash_functions = [_]?HashFunction{
    HashFunction{ .name = "md5", .hclass = &bearssl.br_md5_vtable, .comment = "MD5" },
    HashFunction{ .name = "sha1", .hclass = &bearssl.br_sha1_vtable, .comment = "SHA-1" },
    HashFunction{ .name = "sha224", .hclass = &bearssl.br_sha224_vtable, .comment = "SHA-224" },
    HashFunction{ .name = "sha256", .hclass = &bearssl.br_sha256_vtable, .comment = "SHA-256" },
    HashFunction{ .name = "sha384", .hclass = &bearssl.br_sha384_vtable, .comment = "SHA-384" },
    HashFunction{ .name = "sha512", .hclass = &bearssl.br_sha512_vtable, .comment = "SHA-512" },
    null,
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
        if (hash) |h| {
            const id = (h.hclass.desc >> bearssl.BR_HASHDESC_ID_OFF) & bearssl.BR_HASHDESC_ID_MASK;
            if (id == hash_id) {
                log.debug("Matching Hash: {s}", .{h.name});
                return h.hclass;
            }
        } else break;
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
    log.debug("Choose fired! | ID: {d}", .{policy.id});

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
                            log.debug("Under TLS1.2 | Algo ID: {X}", .{choices.*.algo_id});
                        } else {
                            const id = choose_hash(hashes >> 8);
                            choices.*.algo_id = 0xFF00 + id;
                            log.debug("GEQ TLS1.2 | Algo ID: {X}", .{choices.*.algo_id});
                        }

                        ok = true;
                        break;
                    },
                    else => continue,
                }
            },

            bearssl.BR_SSLKEYX_ECDH_RSA => {
                // TODO: Implement this.
                log.debug("Choosing BR_SSLKEYX_ECDH_RSA | TODO!", .{});
                choices.*.cipher_suite = suites[i][0];
                return 0;
            },

            bearssl.BR_SSLKEYX_ECDH_ECDSA => {
                // TODO: Implement this.
                log.debug("Choosing BR_SSLKEYX_ECDH_RECDSA | TODO!", .{});
                choices.*.cipher_suite = suites[i][0];
                return 0;
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
    log.debug("KeyX fired! | ID: {d}", .{policy.id});
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
    log.debug("Sign fired! | ID: {d}", .{policy.id});

    var hv: [64]u8 = undefined;
    var algo_inner_id = algo_id;
    var hv_inner_len = hv_len;

    if (algo_inner_id >= 0xFF00) {
        log.debug("Copy Branch of Do Sign", .{});
        log.debug("Data: {x}", .{data[0..hv_len]});
        algo_inner_id &= 0xFF;
        std.mem.copyForwards(u8, &hv, data[0..hv_len]);
    } else {
        // Q: Is this even needed? We aren't doing callback
        // hashing so?
        log.err("Triggered Callback Hashing", .{});
        var class: *const bearssl.br_hash_class = undefined;
        var zc: bearssl.br_hash_compat_context = undefined;

        algo_inner_id >>= 8;
        class = get_hash_impl(algo_inner_id) catch {
            log.err("unsupported hash function {d}", .{algo_inner_id});
            return 0;
        };

        class.init.?(&zc.vtable);
        class.update.?(&zc.vtable, data, hv_len);
        class.out.?(&zc.vtable, &hv);
        hv_inner_len = (class.desc >> bearssl.BR_HASHDESC_OUT_OFF) & bearssl.BR_HASHDESC_OUT_MASK;
    }

    var sig_len: usize = 0;

    switch (policy.pkey) {
        .RSA => |_| {
            // TODO: Implement this.
            @panic("not yet supported!");
        },

        .EC => |*inner| {
            const class = get_hash_impl(algo_inner_id) catch {
                log.err("unsupported hash function {d}", .{algo_inner_id});
                return 0;
            };

            if (len < 139) {
                log.err("cannot ECDSA-sign len={d}", .{len});
                return 0;
            }

            log.debug("Cert: {x}", .{std.mem.span(policy.chain[0].data)});
            log.debug("EC Key: {x}", .{inner.x[0..inner.xlen]});
            log.debug("EC key curve: {d}", .{inner.curve});
            log.debug("EC key xlen: {d}", .{inner.xlen});
            log.debug("Hash value length: {d}", .{hv_inner_len});

            sig_len = bearssl.br_ecdsa_sign_asn1_get_default().?(
                bearssl.br_ec_get_default(),
                class,
                &hv,
                inner,
                data,
            );

            if (sig_len == 0) {
                log.err("ECDSA-sign failure", .{});
                return 0;
            }

            return sig_len;
        },
    }

    return 0;
}

const TLSOptions = struct {
    allocator: std.mem.Allocator,
    socket: Socket,
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
    socket: Socket,
    context: bearssl.br_ssl_server_context,
    iobuf: []u8,
    buffer: []u8,
    chain: []const bearssl.br_x509_certificate,
    pkey: PrivateKey,
    policy: *PolicyContext = undefined,

    pub fn init(options: TLSOptions) TLS {
        return .{
            .allocator = options.allocator,
            .socket = options.socket,
            .context = options.context,
            .iobuf = options.allocator.alloc(u8, bearssl.BR_SSL_BUFSIZE_BIDI) catch unreachable,
            .buffer = options.allocator.alloc(u8, 8192) catch unreachable,
            .chain = options.chain,
            .pkey = options.pkey,
            .policy = options.allocator.create(PolicyContext) catch unreachable,
        };
    }

    // THIS WILL DESTROY THE TLS OBJECT!
    pub fn deinit(self: TLS) void {
        self.allocator.free(self.iobuf);
        self.allocator.free(self.chain);
        self.allocator.destroy(self.policy);
    }

    pub fn accept(self: *TLS) !void {
        const engine = &self.context.eng;
        bearssl.br_ssl_engine_set_buffer(engine, self.iobuf.ptr, self.iobuf.len, 1);

        // Build the Policy.
        self.policy.vtable = @constCast(&policy_vtable);
        self.policy.chain = self.chain;
        self.policy.pkey = self.pkey;
        log.debug("Private Key: {x}", .{std.mem.span(self.pkey.EC.x)});
        log.debug("Policy Private Key: {x}", .{std.mem.span(self.policy.pkey.EC.x)});
        self.policy.id = 100;

        bearssl.br_ssl_server_set_policy(&self.context, @ptrCast(&self.policy.vtable));

        const reset_status = bearssl.br_ssl_server_reset(&self.context);
        if (reset_status < 0) {
            return error.ServerResetFailed;
        }

        var cycle_count: u32 = 0;
        while (cycle_count < 50) : (cycle_count += 1) {
            const last_error = bearssl.br_ssl_engine_last_error(engine);
            log.debug("Cycle {d} - Last Error | {d}", .{ cycle_count, last_error });
            if (last_error != 0) {
                log.debug("Cycle {d} - Handshake Failed | {s}", .{
                    cycle_count,
                    fmt_bearssl_error(last_error),
                });
                return error.HandshakeFailed;
            }

            const state = bearssl.br_ssl_engine_current_state(engine);
            log.debug("Cycle {d} - Engine State | {any}", .{ cycle_count, state });

            if ((state & bearssl.BR_SSL_CLOSED) != 0) {
                return error.HandshakeFailed;
            }

            if ((state & bearssl.BR_SSL_SENDAPP) != 0) {
                log.debug("Cycle {d} - Handshake Complete!", .{cycle_count});
                return;
            }

            if ((state & bearssl.BR_SSL_SENDREC) != 0) {
                var length: usize = undefined;
                const buf = bearssl.br_ssl_engine_sendrec_buf(engine, &length);
                log.debug("Cycle {d} - Send Buffer: address={*}, length={d}", .{ cycle_count, buf, length });
                if (length == 0) {
                    continue;
                }

                const sent = try std.posix.send(self.socket, buf[0..length], 0);
                log.debug("Cycle {d} - Total Sent: {d}", .{ cycle_count, sent });

                bearssl.br_ssl_engine_sendrec_ack(engine, sent);
                bearssl.br_ssl_engine_flush(engine, 0);
                continue;
            }

            if ((state & bearssl.BR_SSL_RECVREC) != 0) {
                var length: usize = undefined;
                const buf = bearssl.br_ssl_engine_recvrec_buf(engine, &length);
                log.debug("Cycle {d} - Recv Buffer: address={*}, length={d}", .{ cycle_count, buf, length });
                if (length == 0) {
                    continue;
                }

                const read = try std.posix.recv(self.socket, buf[0..length], 0);
                log.debug("Cycle {d} - Total Read: {d}", .{ cycle_count, read });

                bearssl.br_ssl_engine_recvrec_ack(engine, read);
                continue;
            }

            if ((state & bearssl.BR_SSL_RECVAPP) != 0) {
                return error.UnexpectedState;
            }
        }

        return error.HandshakeTimeout;
    }

    pub fn decrypt(self: *TLS, encrypted: []const u8) ![]const u8 {
        const engine = &self.context.eng;

        var recv_app = false;
        var encrypted_index: usize = 0;
        var decrypted_index: usize = 0;

        var cycle_count: u32 = 0;
        while (cycle_count < 50) : (cycle_count += 1) {
            const last_error = bearssl.br_ssl_engine_last_error(engine);
            log.debug("D Cycle {d} - Last Error | {d}", .{ cycle_count, last_error });
            if (last_error != 0) {
                log.debug("D Cycle {d} - Decrypt Failed | {s}", .{
                    cycle_count,
                    fmt_bearssl_error(last_error),
                });
                return error.DecryptFailed;
            }

            const state = bearssl.br_ssl_engine_current_state(engine);
            log.debug("D Cycle {d} - Engine State | {any}", .{ cycle_count, state });

            if ((state & bearssl.BR_SSL_CLOSED) != 0) {
                return error.DecryptFailed;
            }

            if ((state & bearssl.BR_SSL_RECVREC) != 0) {
                if (recv_app) {
                    return self.buffer[0..decrypted_index];
                }

                log.debug("Triggered BR_SSL_RECVREC", .{});
                // We are writing in the encrypted data...
                var length: usize = undefined;
                const buf = bearssl.br_ssl_engine_recvrec_buf(engine, &length);
                log.debug("D Cycle {d} - Recv Rec Buffer: address={*}, length={d}", .{ cycle_count, buf, length });
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
                log.debug("D Cycle {d} - Total Read: {d}", .{ cycle_count, min_length });
                bearssl.br_ssl_engine_recvrec_ack(engine, min_length);
                continue;
            }

            if ((state & bearssl.BR_SSL_RECVAPP) != 0) {
                recv_app = true;
                // Now we are reading out the decrypted data...
                log.debug("Triggered BR_SSL_RECVAPP", .{});
                var length: usize = undefined;
                const buf = bearssl.br_ssl_engine_recvapp_buf(engine, &length);
                log.debug("D Cycle {d} - Recv App Buffer: address={*}, length={d}", .{ cycle_count, buf, length });

                if (length == 0) {
                    continue;
                }

                const min_length = @min(length, self.buffer.len - decrypted_index);

                std.mem.copyForwards(
                    u8,
                    self.buffer[decrypted_index .. decrypted_index + min_length],
                    buf[0..min_length],
                );
                decrypted_index += min_length;
                log.debug("D Cycle {d} - Total Read: {d}", .{ cycle_count, min_length });
                log.debug("D Cycle {d} - Unencrypted Read: {s}", .{ cycle_count, self.buffer[0 .. decrypted_index - 1] });
                bearssl.br_ssl_engine_recvapp_ack(engine, min_length);
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
        const engine = &self.context.eng;

        log.debug("E - Plaintext Length: {d}", .{plaintext.len});

        var sent_rec = false;
        var plaintext_index: usize = 0;
        var encrypted_index: usize = 0;

        var cycle_count: u32 = 0;
        while (cycle_count < 50) : (cycle_count += 1) {
            const last_error = bearssl.br_ssl_engine_last_error(engine);
            log.debug("E Cycle {d} - Last Error | {d}", .{ cycle_count, last_error });
            if (last_error != 0) {
                log.debug("E Cycle {d} - Encrypt Failed | {s}", .{
                    cycle_count,
                    fmt_bearssl_error(last_error),
                });
                return error.DecryptFailed;
            }

            const state = bearssl.br_ssl_engine_current_state(engine);
            log.debug("E Cycle {d} - Engine State | {any}", .{ cycle_count, state });

            if ((state & bearssl.BR_SSL_CLOSED) != 0) {
                return error.DecryptFailed;
            }

            if ((state & bearssl.BR_SSL_SENDAPP) != 0) {
                log.debug("Triggered BR_SSL_SENDAPP", .{});

                if (sent_rec) {
                    return self.buffer[0..encrypted_index];
                }

                var length: usize = undefined;
                const buf = bearssl.br_ssl_engine_sendapp_buf(engine, &length);

                log.debug("E Cycle {d} - Send App Buffer: address={*}, length={d}", .{ cycle_count, buf, length });
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
                log.debug("E Cycle {d} - Total Send App: {d}", .{ cycle_count, min_length });
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

                log.debug("E Cycle {d} - Send Rec Buffer: address={*}, length={d}", .{ cycle_count, buf, length });
                if (length == 0) {
                    continue;
                }

                const min_length = @min(length, self.buffer.len - encrypted_index);
                std.mem.copyForwards(
                    u8,
                    self.buffer[encrypted_index .. encrypted_index + min_length],
                    buf[0..min_length],
                );

                encrypted_index += min_length;
                log.debug("E Cycle {d} - Total Send Rec: {d}", .{ cycle_count, min_length });
                bearssl.br_ssl_engine_sendrec_ack(engine, min_length);
                continue;
            }

            if ((state & bearssl.BR_SSL_RECVREC) != 0) {}

            if ((state & bearssl.BR_SSL_RECVAPP) != 0) {}
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

    const tls = try context.create();
    defer tls.deinit();
}
