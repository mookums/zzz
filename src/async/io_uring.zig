const std = @import("std");
const Async = @import("lib.zig").Async;
const AsyncError = @import("lib.zig").AsyncError;

pub const Async_IOUring = struct {
    runner: *anyopaque,

    pub fn init() Async_IOUring {
        // This should initialize IO_Uring.
        @panic("TODO!");
    }

    pub fn queue_recv(self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void {
        const uring: *std.os.linux.IoUring = @ptrCast(self.runner);
        _ = try uring.recv(context, socket, .{ .buffer = buffer }, 0);
    }

    pub fn queue_send(self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void {
        const uring: *std.os.linux.IoUring = @ptrCast(self.runner);
        _ = try uring.send(context, socket, buffer, 0);
    }

    pub fn submit(self: *Async) AsyncError!void {
        const uring: *std.os.linux.IoUring = @ptrCast(self.runner);
        try uring.submit();
    }

    pub fn to_async(self: *Async_IOUring) Async {
        return Async{
            .runner = self.runner,
            .queue_send = queue_send,
            .queue_recv = queue_recv,
            .submit = submit,
        };
    }
};
