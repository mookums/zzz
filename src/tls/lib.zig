const std = @import("std");
const log = std.log.scoped(.@"zzz/tls");
const Socket = @import("../core/socket.zig").Socket;

const open = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/bio.h");
    @cInclude("openssl/err.h");
});

pub const TLSContext = struct {
    context: *open.SSL_CTX,

    pub fn init(cert: []const u8, key: []const u8) !TLSContext {
        _ = open.OPENSSL_init_ssl(0, null);
        const method = open.TLS_server_method();
        const ctx = open.SSL_CTX_new(method) orelse return error.TLSContextFailed;
        errdefer open.SSL_CTX_free(ctx);

        _ = open.SSL_CTX_use_certificate_file(ctx, cert.ptr, open.SSL_FILETYPE_PEM);
        _ = open.SSL_CTX_use_PrivateKey_file(ctx, key.ptr, open.SSL_FILETYPE_PEM);

        return .{
            .context = ctx,
        };
    }

    pub fn create(self: TLSContext, socket: Socket) !TLS {
        const tls = open.SSL_new(self.context) orelse return error.TLSCreateFailed;
        errdefer open.SSL_free(tls);

        _ = open.SSL_set_fd(tls, @as(c_int, @intCast(socket)));
        return TLS{
            .tls = tls,
            .r_bio = open.BIO_new(open.BIO_s_mem()).?,
            .w_bio = open.BIO_new(open.BIO_s_mem()).?,
        };
    }

    pub fn deinit(self: TLSContext) void {
        open.SSL_CTX_free(self.context);
    }
};

pub const TLS = struct {
    tls: *open.SSL,
    r_bio: *open.BIO,
    w_bio: *open.BIO,

    pub fn deinit(self: TLS) void {
        open.SSL_free(self.tls);
    }

    pub fn accept(self: *TLS) !void {
        const result = open.SSL_accept(self.tls);
        if (result <= 0) {
            const err = open.SSL_get_error(self.tls, result);
            switch (err) {
                open.SSL_ERROR_WANT_READ, open.SSL_ERROR_WANT_WRITE => return error.WouldBlock,
                else => {
                    const error_string = open.ERR_error_string(open.ERR_get_error(), null);
                    log.debug("SSL_accept failed: {s}\n", .{error_string});
                    return error.SSLAcceptFailed;
                },
            }
        }

        open.SSL_set_bio(self.tls, self.r_bio, self.w_bio);
    }
    pub fn decrypt(self: *TLS, encrypted: []const u8, plaintext: []u8) !void {
        _ = open.BIO_write(self.r_bio, encrypted.ptr, @as(c_int, @intCast(encrypted.len)));
        _ = open.SSL_read(self.tls, plaintext.ptr, @as(c_int, @intCast(plaintext.len)));
    }

    pub fn encrypt(self: *TLS, plaintext: []const u8, encrypted: []u8) !void {
        _ = open.SSL_write(self.tls, plaintext.ptr, @as(c_int, @intCast(plaintext.len)));
        _ = open.BIO_read(self.w_bio, encrypted.ptr, @as(c_int, @intCast(encrypted.len)));
    }
};
