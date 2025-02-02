const std = @import("std");

const Runtime = @import("tardy").Runtime;
const Socket = @import("tardy").Socket;
const Stream = @import("tardy").Stream;

const TLS = @import("../tls/lib.zig").TLS;

pub const SecureSocket = struct {
    inner: Socket,
    tls: ?*TLS = null,

    pub fn init(socket: Socket, tls: *?TLS, rt: *Runtime) !SecureSocket {
        if (tls.*) |*t| {
            const buffer = try t.start_handshake();
            const length = try socket.recv(rt, buffer);
            var state = try t.continue_handshake(.{ .recv = length });

            while (true) {
                switch (state) {
                    .recv => |inner| {
                        const recvd = try socket.recv(rt, inner);
                        state = try t.continue_handshake(.{ .recv = recvd });
                    },
                    .send => |inner| {
                        const sent = try socket.send_all(rt, inner);
                        state = try t.continue_handshake(.{ .send = sent });
                    },
                    .complete => break,
                }
            }

            return .{ .inner = socket, .tls = t };
        } else return .{ .inner = socket, .tls = null };
    }

    pub fn recv(self: SecureSocket, rt: *Runtime, buffer: []u8) !usize {
        if (self.tls) |tls| {
            const recvd = try self.inner.recv(rt, buffer);
            const decrypted = try tls.decrypt(buffer[0..recvd]);
            return decrypted;
        } else return try self.inner.recv(rt, buffer);
    }

    pub fn send_all(self: SecureSocket, rt: *Runtime, buffer: []const u8) !usize {
        if (self.tls) |tls| {
            const encrypted = try tls.encrypt(buffer);
            const sent = try self.inner.send_all(rt, encrypted);
            if (sent == encrypted.len)
                return buffer.len
            else
                return 0;
        } else return try self.inner.send_all(rt, buffer);
    }

    pub fn stream(self: *const SecureSocket) Stream {
        return Stream{
            .inner = @constCast(@ptrCast(self)),
            .vtable = .{
                .read = struct {
                    fn read(inner: *anyopaque, rt: *Runtime, buffer: []u8) !usize {
                        const socket: *SecureSocket = @ptrCast(@alignCast(inner));
                        return try socket.recv(rt, buffer);
                    }
                }.read,
                .write = struct {
                    fn write(inner: *anyopaque, rt: *Runtime, buffer: []const u8) !usize {
                        const socket: *SecureSocket = @ptrCast(@alignCast(inner));
                        return try socket.send_all(rt, buffer);
                    }
                }.write,
            },
        };
    }
};
