const std = @import("std");
const log = std.log.scoped(.@"zzz/tls");

const Socket = @import("../core/socket.zig").Socket;

const bearssl = @cImport({
    @cInclude("bearssl.h");
});

fn parse_pem(allocator: std.mem.Allocator, buffer: []const u8) ![]const u8 {
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

    var written: usize = 0;
    while (true) {
        written += bearssl.br_pem_decoder_push(&p_ctx, buffer[written..].ptr, buffer.len - written);
        const event = bearssl.br_pem_decoder_event(&p_ctx);
        switch (event) {
            0, bearssl.BR_PEM_BEGIN_OBJ => continue,
            bearssl.BR_PEM_END_OBJ => break,
            bearssl.BR_PEM_ERROR => return error.PEMDecodeFailed,
            else => return error.PEMDecodeUnknownEvent,
        }
    }

    return decoded.toOwnedSlice();
}

pub const TLSContext = struct {
    allocator: std.mem.Allocator,
    x509: bearssl.br_x509_certificate,
    pkey: bearssl.br_rsa_private_key,
    cert: []const u8,
    key: []const u8,

    /// This only needs to be called once and it should create all of the stuff needed.
    pub fn init(allocator: std.mem.Allocator, cert_path: []const u8, key_path: []const u8) !TLSContext {
        var self: TLSContext = undefined;
        self.allocator = allocator;

        // Read Certificate.
        const cert_buf = try std.fs.cwd().readFileAlloc(allocator, cert_path, 1024 * 1024);
        defer self.allocator.free(cert_buf);
        const key_buf = try std.fs.cwd().readFileAlloc(allocator, key_path, 1024 * 1024);
        defer self.allocator.free(key_buf);

        self.cert = try parse_pem(allocator, cert_buf);

        var x_ctx: bearssl.br_x509_decoder_context = undefined;
        bearssl.br_x509_decoder_init(&x_ctx, null, null);
        bearssl.br_x509_decoder_push(&x_ctx, self.cert.ptr, self.cert.len);

        if (bearssl.br_x509_decoder_last_error(&x_ctx) != 0) {
            return error.CertificateDecodeFailed;
        }

        self.x509 = bearssl.br_x509_certificate{
            .data = @ptrCast(@constCast(self.cert.ptr)),
            .data_len = @intCast(self.cert.len),
        };

        // Read Private Key.
        self.key = try parse_pem(allocator, key_buf);

        var sk_ctx: bearssl.br_skey_decoder_context = undefined;
        bearssl.br_skey_decoder_init(&sk_ctx);
        bearssl.br_skey_decoder_push(&sk_ctx, self.key.ptr, self.key.len);

        if (bearssl.br_skey_decoder_last_error(&sk_ctx) != 0) {
            return error.PrivateKeyDecodeFailed;
        }

        self.pkey = bearssl.br_skey_decoder_get_rsa(&sk_ctx)[0];
        return self;
    }

    pub fn create(self: TLSContext) !TLS {
        var ctx: bearssl.br_ssl_server_context = undefined;
        bearssl.br_ssl_server_init_full_rsa(&ctx, &self.x509, 1, &self.pkey);

        if (bearssl.br_ssl_engine_last_error(&ctx.eng) != 0) {
            return error.ServerInitializationFailed;
        }

        const cipher_suites = [_]u16{
            bearssl.BR_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
            bearssl.BR_TLS_RSA_WITH_AES_128_GCM_SHA256,
        };

        bearssl.br_ssl_engine_set_suites(&ctx.eng, cipher_suites[0..].ptr, cipher_suites.len);

        return TLS.init(self.allocator, ctx);
    }

    pub fn deinit(self: TLSContext) void {
        self.allocator.free(self.cert);
        self.allocator.free(self.key);
    }
};

pub const TLS = struct {
    allocator: std.mem.Allocator,
    context: bearssl.br_ssl_server_context,
    io_context: bearssl.br_sslio_context,
    iobuf: [bearssl.BR_SSL_BUFSIZE_BIDI]u8,

    pub fn init(allocator: std.mem.Allocator, context: bearssl.br_ssl_server_context) TLS {
        return .{
            .allocator = allocator,
            .context = context,
            .io_context = undefined,
            .iobuf = [1]u8{0} ** bearssl.BR_SSL_BUFSIZE_BIDI,
        };
    }

    pub fn deinit(self: TLS) void {
        _ = self;
    }

    pub fn accept(self: *TLS, socket: Socket) !void {
        _ = socket;
        const engine = &self.context.eng;
        bearssl.br_ssl_engine_set_buffer(engine, &self.iobuf, self.iobuf.len, 1);

        if (bearssl.br_ssl_engine_last_error(engine) != 0) {
            return error.ServerAcceptFailed;
        }

        // Handle the handshake. I think it might be
        // easier to make the handshake blocking for NOW.
        //
        // We can then transition it to work within our main zzz loop.
        while (true) {
            const state = bearssl.br_ssl_engine_current_state(engine);
            switch (state) {
                bearssl.BR_SSL_CLOSED => return error.HandshakeFailed,
                bearssl.BR_SSL_SENDAPP => return,
                bearssl.BR_SSL_RECVREC => {
                    // We need to read data here
                    // Simulate receiving data (in a real scenario, you'd read from the network)
                    var length: usize = undefined;
                    _ = bearssl.br_ssl_engine_recvrec_buf(engine, &length);
                    bearssl.br_ssl_engine_recvrec_ack(engine, 0);
                },
                bearssl.BR_SSL_SENDREC => {
                    // Simulate sending data (in a real scenario, you'd write to the network)
                    var length: usize = undefined;
                    _ = bearssl.br_ssl_engine_sendrec_buf(engine, &length);
                    bearssl.br_ssl_engine_sendrec_ack(engine, length);
                },
                else => {}, // Other states, just continue the loop
            }

            bearssl.br_ssl_engine_flush(engine, 0);

            if (bearssl.br_ssl_engine_last_error(engine) != 0) {
                return error.HandshakeFailed;
            }
        }
    }

    pub fn decrypt(self: *TLS, encrypted: []const u8) []const u8 {
        const engine = &self.context.eng;

        // Push the encrypted data.
        const buffer = bearssl.br_ssl_engine_sendrec_buf(engine, encrypted.len)[0..encrypted.len];
        std.mem.copyForwards(u8, buffer, encrypted);
        bearssl.br_ssl_engine_sendrec_ack(engine, encrypted.len);

        // Read out the plaintext data.
        const unencrypted = bearssl.br_ssl_engine_recvapp_buf(engine, encrypted.len)[0..encrypted.len];
        return unencrypted;
    }

    pub fn encrypt(self: *TLS, plaintext: []const u8) ![]const u8 {
        const engine = &self.context.eng;
        var encrypted = std.ArrayList(u8).init(self.allocator);
        defer encrypted.deinit();

        var total_written: usize = 0;
        const send_rec_state = bearssl.br_ssl_engine_current_state(engine) == bearssl.BR_SSL_SENDREC;
        while (total_written < plaintext.len or send_rec_state) {
            switch (bearssl.br_ssl_engine_current_state(engine)) {
                bearssl.BR_SSL_CLOSED => return error.EngineClosed,
                bearssl.BR_SSL_SENDAPP => {
                    var length: usize = undefined;
                    const rec_buf = bearssl.br_ssl_engine_sendapp_buf(engine, &length);
                    if (length == 0) {
                        continue; // Buffer not ready, try again
                    }
                    const to_write = @min(length, plaintext.len - total_written);
                    std.mem.copyForwards(
                        u8,
                        rec_buf[0..to_write],
                        plaintext[total_written .. total_written + to_write],
                    );
                    bearssl.br_ssl_engine_sendapp_ack(engine, to_write);
                    total_written += to_write;
                },
                bearssl.BR_SSL_SENDREC => {
                    var length: usize = undefined;
                    const encrypted_buf = bearssl.br_ssl_engine_sendrec_buf(engine, &length);
                    if (length == 0) {
                        continue; // Buffer not ready, try again
                    }
                    try encrypted.appendSlice(encrypted_buf[0..length]);
                    bearssl.br_ssl_engine_sendrec_ack(engine, length);
                },
                bearssl.BR_SSL_RECVAPP => return error.UnexpectedRecvApp,
                bearssl.BR_SSL_RECVREC => {
                    var length: usize = undefined;
                    _ = bearssl.br_ssl_engine_recvrec_buf(engine, &length);
                    if (length > 0) {
                        bearssl.br_ssl_engine_recvrec_ack(engine, 0);
                    } else {
                        _ = bearssl.br_ssl_engine_flush(engine, 0);
                    }
                },
                else => return error.UnexpectedState,
            }
        }

        return encrypted.toOwnedSlice();
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
