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

        inner: *std.os.linux.IoUring,
        cqes: []std.os.linux.io_uring_cqe,
        timespec: ?std.os.linux.kernel_timespec = null,

        pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !Self {
            // with io_uring, our timeouts take up an additional slot in the ring.
            // this means if they are enabled, we need 2x the slots.
            const size = blk: {
                if (options.ms_operation_max) |_| {
                    break :blk options.size_connections_max * 2;
                } else {
                    break :blk options.size_connections_max;
                }
            };

            const uring = blk: {
                if (options.in_thread) {
                    assert(options.root_async != null);
                    const parent_uring: *Self = @ptrCast(
                        @alignCast(options.root_async.?.runner),
                    );
                    assert(parent_uring.inner.fd >= 0);

                    // Initialize using the WQ from the parent ring.
                    const flags: u32 = base_flags | std.os.linux.IORING_SETUP_ATTACH_WQ;

                    var params = std.mem.zeroInit(std.os.linux.io_uring_params, .{
                        .flags = flags,
                        .wq_fd = @as(u32, @intCast(parent_uring.inner.fd)),
                    });

                    const uring = try allocator.create(std.os.linux.IoUring);
                    uring.* = try std.os.linux.IoUring.init_params(
                        // TODO: determine if this needs to be doubled with timeouts.
                        std.math.ceilPowerOfTwoAssert(u16, size),
                        &params,
                    );

                    break :blk uring;
                } else {
                    // Initalize IO Uring
                    const uring = try allocator.create(std.os.linux.IoUring);
                    uring.* = try std.os.linux.IoUring.init(
                        std.math.ceilPowerOfTwoAssert(u16, size),
                        base_flags,
                    );

                    break :blk uring;
                }
            };

            const timespec: ?std.os.linux.kernel_timespec = if (options.ms_operation_max) |ms| .{
                .tv_sec = @divFloor(ms, std.time.ms_per_s),
                .tv_nsec = @rem(ms, std.time.ms_per_s) * std.time.ns_per_ms,
            } else null;

            return Self{
                .inner = uring,
                .timespec = timespec,
                .cqes = try allocator.alloc(std.os.linux.io_uring_cqe, options.size_completions_reap_max),
            };
        }

        pub fn deinit(self: *Async, allocator: std.mem.Allocator) void {
            const uring: *Self = @ptrCast(@alignCast(self.runner));
            uring.inner.deinit();
            allocator.free(uring.cqes);
            allocator.destroy(uring.inner);
        }

        pub fn queue_accept(
            self: *Async,
            context: *anyopaque,
            socket: std.posix.socket_t,
        ) AsyncError!void {
            const ctx = @as(u64, @intFromPtr(context));

            const uring: *Self = @ptrCast(@alignCast(self.runner));
            const sqe = uring.inner.accept(ctx, socket, null, null, 0) catch |e| switch (e) {
                error.SubmissionQueueFull => return AsyncError.QueueFull,
                else => unreachable,
            };

            if (uring.timespec) |*ts| {
                sqe.flags |= std.os.linux.IOSQE_IO_LINK;
                _ = uring.inner.link_timeout(ctx, ts, 0) catch |e| switch (e) {
                    error.SubmissionQueueFull => return AsyncError.QueueFull,
                    else => unreachable,
                };
            }
        }

        pub fn queue_recv(
            self: *Async,
            context: *anyopaque,
            socket: std.posix.socket_t,
            buffer: []u8,
        ) AsyncError!void {
            const ctx = @as(u64, @intFromPtr(context));

            const uring: *Self = @ptrCast(@alignCast(self.runner));
            const sqe = uring.inner.recv(ctx, socket, .{ .buffer = buffer }, 0) catch |e| switch (e) {
                error.SubmissionQueueFull => return AsyncError.QueueFull,
                else => unreachable,
            };

            if (uring.timespec) |*ts| {
                sqe.flags |= std.os.linux.IOSQE_IO_LINK;
                _ = uring.inner.link_timeout(ctx, ts, 0) catch |e| switch (e) {
                    error.SubmissionQueueFull => return AsyncError.QueueFull,
                    else => unreachable,
                };
            }
        }

        pub fn queue_send(
            self: *Async,
            context: *anyopaque,
            socket: std.posix.socket_t,
            buffer: []const u8,
        ) AsyncError!void {
            const ctx = @as(u64, @intFromPtr(context));

            const uring: *Self = @ptrCast(@alignCast(self.runner));
            const sqe = uring.inner.send(ctx, socket, buffer, 0) catch |e| switch (e) {
                error.SubmissionQueueFull => return AsyncError.QueueFull,
                else => unreachable,
            };

            if (uring.timespec) |*ts| {
                sqe.flags |= std.os.linux.IOSQE_IO_LINK;
                _ = uring.inner.link_timeout(ctx, ts, 0) catch |e| switch (e) {
                    error.SubmissionQueueFull => return AsyncError.QueueFull,
                    else => unreachable,
                };
            }
        }

        pub fn queue_close(
            self: *Async,
            context: *anyopaque,
            fd: std.posix.fd_t,
        ) AsyncError!void {
            const uring: *Self = @ptrCast(@alignCast(self.runner));
            _ = uring.inner.close(@as(u64, @intFromPtr(context)), fd) catch |e| switch (e) {
                error.SubmissionQueueFull => return AsyncError.QueueFull,
                else => unreachable,
            };
        }

        pub fn submit(self: *Async) AsyncError!void {
            const uring: *Self = @ptrCast(@alignCast(self.runner));
            _ = uring.inner.submit() catch |e| switch (e) {
                // TODO: match error states.
                else => unreachable,
            };
        }

        pub fn reap(self: *Async) AsyncError![]Completion {
            const uring: *Self = @ptrCast(@alignCast(self.runner));

            const min_length = @min(uring.cqes.len, self.completions.len);
            const count = uring.inner.copy_cqes(uring.cqes[0..min_length], 1) catch |e| switch (e) {
                // TODO: match error states.
                else => unreachable,
            };

            for (uring.cqes[0..count], 0..) |cqe, i| {
                const provision: *Provision = @ptrFromInt(@as(usize, cqe.user_data));

                const result: Completion.Result = blk: {
                    if (cqe.res >= 0) {
                        if (provision.job == .accept) {
                            break :blk .{ .socket = cqe.res };
                        } else {
                            break :blk .{ .value = cqe.res };
                        }
                    } else {
                        switch (-cqe.res) {
                            @intFromEnum(std.os.linux.E.TIME) => break :blk .timeout,
                            @intFromEnum(std.os.linux.E.CANCELED) => break :blk .canceled,
                            else => {
                                log.debug("{d} - other status on SQE: {s}", .{
                                    provision.index,
                                    @tagName(@as(std.os.linux.E, @enumFromInt(-cqe.res))),
                                });

                                if (provision.job == .accept) {
                                    break :blk .{ .socket = cqe.res };
                                } else {
                                    break :blk .{ .value = cqe.res };
                                }
                            },
                        }
                    }
                };

                self.completions[i] = Completion{
                    .result = result,
                    .context = @ptrFromInt(@as(usize, @intCast(cqe.user_data))),
                };
            }

            return self.completions[0..count];
        }

        pub fn to_async(self: *Self) Async {
            return Async{
                .runner = self,
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
