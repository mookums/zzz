const std = @import("std");
const assert = std.debug.assert;
const Completion = @import("completion.zig").Completion;
const Async = @import("lib.zig").Async;
const AsyncError = @import("lib.zig").AsyncError;
const AsyncOptions = @import("lib.zig").AsyncOptions;

const log = std.log.scoped(.@"zzz/async/io_uring");

pub fn AsyncIoUring(comptime Provision: type) type {
    return struct {
        const Self = @This();
        const base_flags = blk: {
            var flags = std.os.linux.IORING_SETUP_COOP_TASKRUN;
            flags |= std.os.linux.IORING_SETUP_DEFER_TASKRUN;
            flags |= std.os.linux.IORING_SETUP_SINGLE_ISSUER;
            break :blk flags;
        };
        runner: *anyopaque,

        pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !Self {
            const uring = blk: {
                if (options.in_thread) {
                    assert(options.root_async != null);
                    const parent_uring: *std.os.linux.IoUring = @ptrCast(
                        @alignCast(options.root_async.?.runner),
                    );
                    assert(parent_uring.fd >= 0);

                    // Initialize using the WQ from the parent ring.
                    const flags: u32 = base_flags | std.os.linux.IORING_SETUP_ATTACH_WQ;

                    var params = std.mem.zeroInit(std.os.linux.io_uring_params, .{
                        .flags = flags,
                        .wq_fd = @as(u32, @intCast(parent_uring.fd)),
                    });

                    const uring = try allocator.create(std.os.linux.IoUring);
                    uring.* = try std.os.linux.IoUring.init_params(
                        std.math.ceilPowerOfTwoAssert(u16, options.size_connections_max),
                        &params,
                    );

                    break :blk uring;
                } else {
                    // Initalize IO Uring
                    const uring = try allocator.create(std.os.linux.IoUring);
                    uring.* = try std.os.linux.IoUring.init(
                        std.math.ceilPowerOfTwoAssert(u16, options.size_connections_max),
                        base_flags,
                    );

                    break :blk uring;
                }
            };

            return Self{ .runner = uring };
        }

        pub fn deinit(self: *Async, allocator: std.mem.Allocator) void {
            const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
            uring.deinit();
            allocator.destroy(uring);
        }

        pub fn queue_accept(
            self: *Async,
            context: *anyopaque,
            socket: std.posix.socket_t,
        ) AsyncError!void {
            const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
            _ = uring.accept(@as(u64, @intFromPtr(context)), socket, null, null, 0) catch |e| switch (e) {
                error.SubmissionQueueFull => return AsyncError.QueueFull,
                else => unreachable,
            };
        }

        pub fn queue_recv(
            self: *Async,
            context: *anyopaque,
            socket: std.posix.socket_t,
            buffer: []u8,
        ) AsyncError!void {
            const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
            _ = uring.recv(@as(u64, @intFromPtr(context)), socket, .{ .buffer = buffer }, 0) catch |e| switch (e) {
                error.SubmissionQueueFull => return AsyncError.QueueFull,
                else => unreachable,
            };
        }

        pub fn queue_send(
            self: *Async,
            context: *anyopaque,
            socket: std.posix.socket_t,
            buffer: []const u8,
        ) AsyncError!void {
            const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
            _ = uring.send(@as(u64, @intFromPtr(context)), socket, buffer, 0) catch |e| switch (e) {
                error.SubmissionQueueFull => return AsyncError.QueueFull,
                else => unreachable,
            };
        }

        pub fn queue_close(
            self: *Async,
            context: *anyopaque,
            fd: std.posix.fd_t,
        ) AsyncError!void {
            const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
            _ = uring.close(@as(u64, @intFromPtr(context)), fd) catch |e| switch (e) {
                error.SubmissionQueueFull => return AsyncError.QueueFull,
                else => unreachable,
            };
        }

        pub fn submit(self: *Async) AsyncError!void {
            const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
            _ = uring.submit() catch |e| switch (e) {
                // TODO: match error states.
                else => unreachable,
            };
        }

        pub fn reap(self: *Async) AsyncError![]Completion {
            const uring: *std.os.linux.IoUring = @ptrCast(@alignCast(self.runner));
            // NOTE: this can be dynamic and then we would just have to make a single call
            // which would probably be better.
            var cqes: [256]std.os.linux.io_uring_cqe = [_]std.os.linux.io_uring_cqe{undefined} ** 256;
            var total_reaped: u64 = 0;

            const min_length = @min(cqes.len, self.completions.len);
            {
                // only the first one blocks waiting for an initial set of completions.
                const count = uring.copy_cqes(cqes[0..min_length], 1) catch |e| switch (e) {
                    // TODO: match error states.
                    else => unreachable,
                };

                total_reaped += count;

                // Copy over the first one.
                for (0..total_reaped) |i| {
                    const provision: *Provision = @ptrFromInt(@as(usize, cqes[i].user_data));

                    const result: Completion.Result = if (provision.job == .accept) .{
                        .socket = cqes[i].res,
                    } else .{
                        .value = cqes[i].res,
                    };

                    self.completions[i] = Completion{
                        .result = result,
                        .context = @ptrFromInt(@as(usize, @intCast(cqes[i].user_data))),
                    };
                }
            }

            while (total_reaped < self.completions.len) {
                const start = total_reaped;
                const remaining = self.completions.len - total_reaped;

                const count = uring.copy_cqes(cqes[0..remaining], 0) catch |e| switch (e) {
                    // TODO: match error states.
                    else => unreachable,
                };

                if (count == 0) {
                    return self.completions[0..total_reaped];
                }

                total_reaped += count;

                for (start..total_reaped) |i| {
                    const cqe_index = i - start;
                    const provision: *Provision = @ptrFromInt(@as(usize, cqes[cqe_index].user_data));

                    const result: Completion.Result = if (provision.job == .accept) .{
                        .socket = cqes[cqe_index].res,
                    } else .{
                        .value = cqes[cqe_index].res,
                    };

                    self.completions[i] = Completion{
                        .result = result,
                        .context = @ptrFromInt(@as(usize, @intCast(cqes[cqe_index].user_data))),
                    };
                }
            }

            return self.completions[0..total_reaped];
        }

        pub fn to_async(self: *Self) Async {
            return Async{
                .runner = self.runner,
                ._deinit = deinit,
                ._queue_accept = queue_accept,
                ._queue_recv = queue_recv,
                ._queue_send = queue_send,
                ._queue_close = queue_close,
                ._submit = submit,
                ._reap = reap,
            };
        }
    };
}
