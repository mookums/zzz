const std = @import("std");
const Completion = @import("completion.zig").Completion;
const Async = @import("lib.zig").Async;
const AsyncError = @import("lib.zig").AsyncError;

const log = std.log.scoped(.@"async/io_uring");

pub const AsyncIoUring = struct {
    runner: *anyopaque,
    completions: [256]Completion,

    pub fn init(uring: *std.os.linux.IoUring) !AsyncIoUring {
        return AsyncIoUring{
            .runner = uring,
            .completions = [_]Completion{undefined} ** 256,
        };
    }

    pub fn queue_accept(self: *Async, context: *anyopaque, socket: std.posix.socket_t) AsyncError!void {
        const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
        _ = uring.accept(@as(u64, @intFromPtr(context)), socket, null, null, 0) catch unreachable;
    }

    pub fn queue_recv(self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void {
        const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
        _ = uring.recv(@as(u64, @intFromPtr(context)), socket, .{ .buffer = buffer }, 0) catch unreachable;
    }

    pub fn queue_send(self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []const u8) AsyncError!void {
        const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
        _ = uring.send(@as(u64, @intFromPtr(context)), socket, buffer, 0) catch unreachable;
    }

    pub fn submit(self: *Async) AsyncError!void {
        const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
        _ = uring.submit() catch unreachable;
    }

    pub fn reap(self: *Async) AsyncError![]Completion {
        const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
        var cqes: [256]std.os.linux.io_uring_cqe = [_]std.os.linux.io_uring_cqe{undefined} ** 256;
        const count = uring.copy_cqes(cqes[0..], 1) catch unreachable;

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
            .completions = self.completions,
            ._queue_accept = queue_accept,
            ._queue_send = queue_send,
            ._queue_recv = queue_recv,
            ._submit = submit,
            ._reap = reap,
        };
    }
};
