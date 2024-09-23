const std = @import("std");
const Completion = @import("completion.zig").Completion;

const Async = @import("lib.zig").Async;
const AsyncError = @import("lib.zig").AsyncError;
const AsyncOptions = @import("lib.zig").AsyncOptions;

const log = std.log.scoped(.@"zzz/async/busy_loop");

pub const AsyncBusyLoop = struct {
    pub const BusyLoopJob = union(enum) {
        accept: struct { socket: std.posix.socket_t, context: *anyopaque },
        recv: struct { socket: std.posix.socket_t, context: *anyopaque, buffer: []u8 },
        send: struct { socket: std.posix.socket_t, context: *anyopaque, buffer: []const u8 },
        close: struct { socket: std.posix.socket_t, context: *anyopaque },
    };

    inner: *std.ArrayList(BusyLoopJob),

    pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !AsyncBusyLoop {
        _ = options;
        const list = try allocator.create(std.ArrayList(BusyLoopJob));
        list.* = std.ArrayList(BusyLoopJob).init(allocator);
        return AsyncBusyLoop{ .inner = list };
    }

    pub fn deinit(self: *Async, allocator: std.mem.Allocator) void {
        const list: *std.ArrayList(BusyLoopJob) = @ptrCast(@alignCast(self.runner));
        list.deinit();
        allocator.destroy(list);
    }

    pub fn queue_accept(self: *Async, ctx: *anyopaque, socket: std.posix.socket_t) AsyncError!void {
        const list: *std.ArrayList(BusyLoopJob) = @ptrCast(@alignCast(self.runner));
        list.append(BusyLoopJob{ .accept = .{ .socket = socket, .context = ctx } }) catch unreachable;
    }

    pub fn queue_recv(self: *Async, ctx: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void {
        const list: *std.ArrayList(BusyLoopJob) = @ptrCast(@alignCast(self.runner));
        list.append(BusyLoopJob{ .recv = .{ .socket = socket, .context = ctx, .buffer = buffer } }) catch unreachable;
    }

    pub fn queue_send(self: *Async, ctx: *anyopaque, socket: std.posix.socket_t, buffer: []const u8) AsyncError!void {
        const list: *std.ArrayList(BusyLoopJob) = @ptrCast(@alignCast(self.runner));
        list.append(BusyLoopJob{ .send = .{ .socket = socket, .context = ctx, .buffer = buffer } }) catch unreachable;
    }

    pub fn queue_close(self: *Async, ctx: *anyopaque, socket: std.posix.socket_t) AsyncError!void {
        const list: *std.ArrayList(BusyLoopJob) = @ptrCast(@alignCast(self.runner));
        list.append(BusyLoopJob{ .close = .{ .socket = socket, .context = ctx } }) catch unreachable;
    }

    pub fn submit(self: *Async) AsyncError!void {
        _ = self;
    }

    pub fn reap(self: *Async) AsyncError![]Completion {
        const list: *std.ArrayList(BusyLoopJob) = @ptrCast(@alignCast(self.runner));
        var reaped: usize = 0;

        while (reaped < 1) {
            var i: usize = 0;

            while (i < list.items.len and reaped < self.completions.len) : (i += 1) {
                const item = list.items[i];
                switch (item) {
                    .accept => |inner| {
                        const com_ptr = &self.completions[reaped];

                        const res: i32 = blk: {
                            const ad = std.posix.accept(inner.socket, null, null, 0) catch |e| {
                                if (e == error.WouldBlock) {
                                    continue;
                                } else {
                                    break :blk -1;
                                }
                            };

                            break :blk @intCast(ad);
                        };

                        com_ptr.result = @intCast(res);
                        com_ptr.context = inner.context;
                        _ = list.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },

                    .recv => |inner| {
                        const com_ptr = &self.completions[reaped];
                        const len: i32 = blk: {
                            const rd = std.posix.recv(inner.socket, inner.buffer, 0) catch |e| {
                                if (e == error.WouldBlock) {
                                    continue;
                                } else {
                                    break :blk -1;
                                }
                            };

                            break :blk @intCast(rd);
                        };

                        com_ptr.result = @intCast(len);
                        com_ptr.context = inner.context;
                        _ = list.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },

                    .send => |inner| {
                        const com_ptr = &self.completions[reaped];
                        const len: i32 = blk: {
                            const sd = std.posix.send(inner.socket, inner.buffer, 0) catch |e| {
                                if (e == error.WouldBlock) {
                                    continue;
                                } else {
                                    break :blk -1;
                                }
                            };

                            break :blk @intCast(sd);
                        };

                        com_ptr.result = @intCast(len);
                        com_ptr.context = inner.context;
                        _ = list.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },

                    .close => |inner| {
                        const com_ptr = &self.completions[reaped];
                        std.posix.close(inner.socket);
                        com_ptr.result = 0;
                        com_ptr.context = inner.context;
                        _ = list.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },
                }
            }
        }

        return self.completions[0..reaped];
    }

    pub fn to_async(self: *AsyncBusyLoop) Async {
        return Async{
            .runner = self.inner,
            ._deinit = deinit,
            ._queue_accept = queue_accept,
            ._queue_recv = queue_recv,
            ._queue_send = queue_send,
            ._queue_close = undefined,
            ._submit = submit,
            ._reap = reap,
        };
    }
};
