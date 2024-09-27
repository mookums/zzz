const std = @import("std");
const builtin = @import("builtin");
const Completion = @import("completion.zig").Completion;

const Async = @import("lib.zig").Async;
const AsyncError = @import("lib.zig").AsyncError;
const AsyncOptions = @import("lib.zig").AsyncOptions;

const log = std.log.scoped(.@"zzz/async/busy_loop");

pub const AsyncBusyLoop = struct {
    pub const Job = union(enum) {
        accept: struct { socket: std.posix.socket_t, context: *anyopaque },
        recv: struct { socket: std.posix.socket_t, context: *anyopaque, buffer: []u8 },
        send: struct { socket: std.posix.socket_t, context: *anyopaque, buffer: []const u8 },
        close: struct { socket: std.posix.socket_t, context: *anyopaque },
    };

    inner: *std.ArrayList(Job),

    pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !AsyncBusyLoop {
        const list = try allocator.create(std.ArrayList(Job));
        list.* = try std.ArrayList(Job).initCapacity(allocator, options.size_connections_max);
        return AsyncBusyLoop{ .inner = list };
    }

    pub fn deinit(self: *Async, allocator: std.mem.Allocator) void {
        const list: *std.ArrayList(Job) = @ptrCast(@alignCast(self.runner));
        list.deinit();
        allocator.destroy(list);
    }

    pub fn queue_accept(self: *Async, ctx: *anyopaque, socket: std.posix.socket_t) AsyncError!void {
        const list: *std.ArrayList(Job) = @ptrCast(@alignCast(self.runner));
        list.appendAssumeCapacity(Job{ .accept = .{ .socket = socket, .context = ctx } });
    }

    pub fn queue_recv(self: *Async, ctx: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void {
        const list: *std.ArrayList(Job) = @ptrCast(@alignCast(self.runner));
        list.appendAssumeCapacity(Job{ .recv = .{ .socket = socket, .context = ctx, .buffer = buffer } });
    }

    pub fn queue_send(self: *Async, ctx: *anyopaque, socket: std.posix.socket_t, buffer: []const u8) AsyncError!void {
        const list: *std.ArrayList(Job) = @ptrCast(@alignCast(self.runner));
        list.appendAssumeCapacity(Job{ .send = .{ .socket = socket, .context = ctx, .buffer = buffer } });
    }

    pub fn queue_close(self: *Async, ctx: *anyopaque, socket: std.posix.socket_t) AsyncError!void {
        const list: *std.ArrayList(Job) = @ptrCast(@alignCast(self.runner));
        list.appendAssumeCapacity(Job{ .close = .{ .socket = socket, .context = ctx } });
    }

    pub fn submit(self: *Async) AsyncError!void {
        _ = self;
    }

    pub fn reap(self: *Async) AsyncError![]Completion {
        const list: *std.ArrayList(Job) = @ptrCast(@alignCast(self.runner));
        var reaped: usize = 0;

        while (reaped < 1) {
            var i: usize = 0;

            while (i < list.items.len and reaped < self.completions.len) : (i += 1) {
                const item = list.items[i];
                switch (item) {
                    .accept => |inner| {
                        const com_ptr = &self.completions[reaped];

                        const res: std.posix.socket_t = blk: {
                            const accept_result = std.posix.accept(inner.socket, null, null, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => continue,
                                    error.ConnectionResetByPeer => if (comptime builtin.target.os.tag == .windows) {
                                        break :blk std.os.windows.ws2_32.INVALID_SOCKET;
                                    } else {
                                        break :blk 0;
                                    },
                                    else => if (comptime builtin.target.os.tag == .windows) {
                                        break :blk std.os.windows.ws2_32.INVALID_SOCKET;
                                    } else {
                                        log.debug("accept failed: {}", .{e});
                                        break :blk -1;
                                    },
                                }
                            };

                            break :blk accept_result;
                        };

                        com_ptr.result = .{ .socket = res };
                        com_ptr.context = inner.context;
                        _ = list.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },

                    .recv => |inner| {
                        const com_ptr = &self.completions[reaped];
                        const len: i32 = blk: {
                            const read_len = std.posix.recv(inner.socket, inner.buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => continue,
                                    error.ConnectionResetByPeer => break :blk 0,
                                    else => {
                                        log.debug("recv failed: {}", .{e});
                                        break :blk -1;
                                    },
                                }
                            };

                            break :blk @intCast(read_len);
                        };

                        com_ptr.result = .{ .value = @intCast(len) };
                        com_ptr.context = inner.context;
                        _ = list.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },

                    .send => |inner| {
                        const com_ptr = &self.completions[reaped];
                        const len: i32 = blk: {
                            const send_len = std.posix.send(inner.socket, inner.buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => continue,
                                    error.ConnectionResetByPeer => break :blk 0,
                                    else => {
                                        log.debug("send failed: {}", .{e});
                                        break :blk -1;
                                    },
                                }
                            };

                            break :blk @intCast(send_len);
                        };

                        com_ptr.result = .{ .value = @intCast(len) };
                        com_ptr.context = inner.context;
                        _ = list.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },

                    .close => |inner| {
                        const com_ptr = &self.completions[reaped];
                        std.posix.close(inner.socket);
                        com_ptr.result = .{ .value = 0 };
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
