const std = @import("std");
const Completion = @import("completion.zig").Completion;
const Async = @import("lib.zig").Async;
const AsyncError = @import("lib.zig").AsyncError;

pub const AsyncIoUring = struct {
    pub fn init(size_connections_max: u32, params: std.os.linux.io_uring_params) AsyncIoUring {
        // This should initialize IO_Uring.
        var uring = try std.os.linux.IoUring.init_params(
            size_connections_max,
            &params,
        );

        return AsyncIoUring{
            .runner = &uring,
            .cqes = [_]std.os.linux.io_uring_cqe{undefined} ** 256,
            .completions = [_]Completion{undefined} ** 256,
        };
    }

    pub fn queue_accept(self: *Async, context: *anyopaque, socket: std.posix.socket_t) AsyncError!void {
        const uring: *std.os.linux.IoUring = @ptrCast(self.runner);
        _ = try uring.accept(@as(u64, @intFromPtr(context)), socket, null, null, 0);
    }

    pub fn queue_recv(self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void {
        const uring: *std.os.linux.IoUring = @ptrCast(self.runner);
        _ = try uring.recv(@as(u64, @intFromPtr(context)), socket, .{ .buffer = buffer }, 0);
    }

    pub fn queue_send(self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void {
        const uring: *std.os.linux.IoUring = @ptrCast(self.runner);
        _ = try uring.send(@as(u64, @intFromPtr(context)), socket, buffer, 0);
    }

    pub fn submit(self: *Async) AsyncError!void {
        const uring: *std.os.linux.IoUring = @ptrCast(self.runner);
        try uring.submit();
    }

    pub fn reap(self: *Async) AsyncError![]Completion {
        const uring: *std.os.linux.IoUring = @ptrCast(self.runner);
        var cqes: [256]std.os.linux.io_uring_cqe = [_]std.os.linux.io_uring_cqe{undefined} ** 256;
        const count = try uring.copy_cqes(cqes[0..], 1);

        const min = @min(self.completions.len, count);

        for (0..min) |i| {
            self.completions[i] = Completion{
                .result = cqes[i].res,
                .context = @ptrFromInt(cqes[i].user_data),
            };
        }

        return self.completions[0..min];
    }

    pub fn to_async(self: *AsyncIoUring) Async {
        return Async{
            .runner = self.runner,
            .queue_send = queue_send,
            .queue_recv = queue_recv,
            .submit = submit,
        };
    }
};
