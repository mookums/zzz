const std = @import("std");
const log = std.log.scoped(.@"zzz/tls");

const Socket = @import("../core/socket.zig").Socket;

const bearssl = @cImport({
    @cInclude("bearssl.h");
});

pub const TLSContext = struct {
    allocator: std.mem.Allocator,
    x509: bearssl.br_x509_certificate,
    pkey: bearssl.br_rsa_private_key,
    cert_buf: []const u8,
    key_buf: []const u8,

    /// This only needs to be called once and it should create all of the stuff needed.
    pub fn init(allocator: std.mem.Allocator, cert_path: []const u8, key_path: []const u8) !TLSContext {
        var self: TLSContext = undefined;
        self.allocator = allocator;

        // Read Certificate.
        var x_ctx: bearssl.br_x509_decoder_context = undefined;
        bearssl.br_x509_decoder_init(&x_ctx, null, null);

        self.cert_buf = try std.fs.cwd().readFileAlloc(allocator, cert_path, 1024 * 1024);
        bearssl.br_x509_decoder_push(&x_ctx, self.cert_buf.ptr, self.cert_buf.len);

        if (bearssl.br_x509_decoder_last_error(&x_ctx) != 0) {
            return error.CertificateDecodeFailed;
        }

        self.x509 = bearssl.br_x509_certificate{
            .data = @ptrCast(@constCast(self.cert_buf.ptr)),
            .data_len = @intCast(self.cert_buf.len),
        };

        // Read Private Key.
        var sk_ctx: bearssl.br_skey_decoder_context = undefined;
        bearssl.br_skey_decoder_init(&sk_ctx);
        self.key_buf = try std.fs.cwd().readFileAlloc(allocator, key_path, 1024 * 1024);

        bearssl.br_skey_decoder_push(&sk_ctx, self.key_buf.ptr, self.key_buf.len);

        if (bearssl.br_skey_decoder_last_error(&sk_ctx) != 0) {
            return error.PrivateKeyDecodeFailed;
        }

        self.pkey = bearssl.br_skey_decoder_get_rsa(&sk_ctx)[0];
        return self;
    }

    pub fn create(self: TLSContext) TLS {
        var ctx: bearssl.br_ssl_server_context = undefined;
        bearssl.br_ssl_server_init_full_rsa(&ctx, &self.x509, 1, &self.pkey);

        const cipher_suites = [_]u16{
            bearssl.BR_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
            bearssl.BR_TLS_RSA_WITH_AES_128_GCM_SHA256,
        };

        bearssl.br_ssl_engine_set_suites(&ctx.eng, cipher_suites[0..].ptr, cipher_suites.len);

        return TLS.init(ctx);
    }

    pub fn deinit(self: TLSContext) void {
        self.allocator.free(self.cert_buf);
        self.allocator.free(self.key_buf);
    }
};

pub const TLS = struct {
    context: bearssl.br_ssl_server_context,
    iobuf: [bearssl.BR_SSL_BUFSIZE_BIDI]u8,

    pub fn init(context: bearssl.br_ssl_server_context) TLS {
        return .{
            .context = context,
            .iobuf = [1]u8{0} ** bearssl.BR_SSL_BUFSIZE_BIDI,
        };
    }

    pub fn deinit(self: TLS) void {
        _ = self;
    }

    pub fn accept(self: *TLS) !void {
        const engine = &self.context.eng;
        bearssl.br_ssl_engine_set_buffer(engine, self.iobuf, bearssl.BR_SSL_BUFSIZE_BIDI, 1);
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

    pub fn encrypt(self: *TLS, plaintext: []const u8) []const u8 {
        const engine = &self.context.eng;

        const buffer = bearssl.br_ssl_engine_sendapp_buf(engine, plaintext.len)[0..plaintext.len];
        std.mem.copyForwards(u8, buffer, plaintext);
        bearssl.br_ssl_engine_sendapp_ack(engine, plaintext.len);

        const encrypted = bearssl.br_ssl_engine_recvrec_buf(engine, plaintext.len)[0..plaintext.len];
        return encrypted;
    }
};
