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

        return TLS.init(tls);
    }

    pub fn deinit(self: TLSContext) void {
        open.SSL_CTX_free(self.context);
    }
};

pub const TLS = struct {
    buffer: [8192]u8 = [_]u8{undefined} ** 8192,
    tls: *open.SSL,
    r_bio: *open.BIO,
    w_bio: *open.BIO,

    pub fn init(tls: *open.SSL) TLS {
        const r_bio = open.BIO_new(open.BIO_s_mem()).?;
        const w_bio = open.BIO_new(open.BIO_s_mem()).?;

        _ = open.BIO_set_write_buf_size(r_bio, 4096);
        _ = open.BIO_set_write_buf_size(w_bio, 4096);

        return TLS{
            .tls = tls,
            .r_bio = r_bio,
            .w_bio = w_bio,
        };
    }

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

    pub fn decrypt(self: *TLS, encrypted: []const u8) ![]const u8 {
        var total_read: usize = 0;
        var total_written: usize = 0;

        while (total_written < encrypted.len) {
            const write_len = open.BIO_write(
                self.r_bio,
                encrypted[total_written..].ptr,
                @intCast(encrypted.len - total_written),
            );

            if (write_len <= 0) {
                return error.BIOWriteError;
            }

            total_written += @intCast(write_len);
        }

        while (true) {
            const read_len = open.SSL_read(
                self.tls,
                self.buffer[total_read..].ptr,
                @intCast(self.buffer.len - total_read),
            );

            if (read_len <= 0) {
                const err = open.SSL_get_error(self.tls, read_len);
                if (err == open.SSL_ERROR_WANT_READ or err == open.SSL_ERROR_WANT_WRITE) {
                    continue;
                }
                return error.SSLReadError;
            }

            total_read += @intCast(read_len);

            if (open.SSL_pending(self.tls) == 0) {
                break;
            }

            if (total_read == self.buffer.len) {
                return error.BufferTooSmall;
            }
        }

        return self.buffer[0..total_read];
    }

    pub fn encrypt(self: *TLS, plaintext: []const u8) ![]const u8 {
        var total_written: usize = 0;
        var total_read: usize = 0;

        while (total_written < plaintext.len) {
            const write_len = open.SSL_write(
                self.tls,
                plaintext[total_written..].ptr,
                @intCast(plaintext.len - total_written),
            );

            if (write_len <= 0) {
                return error.SSLWriteError;
            }

            total_written += @intCast(write_len);
        }

        while (true) {
            const read_len = open.BIO_read(
                self.w_bio,
                self.buffer[total_read..].ptr,
                @intCast(self.buffer.len - total_read),
            );

            if (read_len <= 0) {
                if (open.BIO_should_retry(self.w_bio) != 0) {
                    continue;
                }
                return error.BIOReadError;
            }

            total_read += @intCast(read_len);

            if (open.BIO_pending(self.w_bio) == 0) {
                break;
            }

            if (total_read == self.buffer.len) {
                return error.BufferTooSmall;
            }
        }

        return self.buffer[0..total_read];
    }
};
