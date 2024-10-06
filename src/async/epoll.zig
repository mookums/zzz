const std = @import("std");
const assert = std.debug.assert;
const Completion = @import("completion.zig").Completion;
const Async = @import("lib.zig").Async;
const AsyncError = @import("lib.zig").AsyncError;
const AsyncOptions = @import("lib.zig").AsyncOptions;
const Pool = @import("../core/pool.zig").Pool;

const log = std.log.scoped(.@"zzz/async/epoll");

pub const AsyncEpoll = struct {
    const Self = @This();

    epoll_fd: std.posix.fd_t,
    events: []std.os.linux.epoll_event,
    jobs: Pool(Job),
    timeout: ?u32,

    const Job = struct {
        type: union(enum) {
            accept,
            recv: []u8,
            send: []const u8,
            close,
        },

        index: usize,
        socket: std.posix.socket_t,
        context: *anyopaque,
        time: ?i64,
    };

    pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !Self {
        const epoll_fd = try std.posix.epoll_create1(0);
        assert(epoll_fd > -1);

        const events = try allocator.alloc(std.os.linux.epoll_event, options.size_connections_max);
        const jobs = try Pool(Job).init(allocator, options.size_connections_max, null, null);

        return Self{
            .epoll_fd = epoll_fd,
            .events = events,
            .jobs = jobs,
            .timeout = options.ms_operation_max,
        };
    }

    pub fn deinit(self: *Async, allocator: std.mem.Allocator) void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        std.posix.close(epoll.epoll_fd);
        allocator.free(epoll.events);
        epoll.jobs.deinit(null, null);
    }

    pub fn queue_accept(
        self: *Async,
        context: *anyopaque,
        socket: std.posix.socket_t,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const borrowed = epoll.jobs.borrow() catch return error.QueueFull;
        borrowed.item.* = .{
            .index = borrowed.index,
            .socket = socket,
            .context = context,
            .type = .accept,
            .time = null,
        };

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.EXCLUSIVE,
            .data = .{ .u64 = borrowed.index },
        };

        epoll.add_fd(socket, &event) catch unreachable;
    }

    pub fn queue_recv(
        self: *Async,
        context: *anyopaque,
        socket: std.posix.socket_t,
        buffer: []u8,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const borrowed = epoll.jobs.borrow() catch return error.QueueFull;
        borrowed.item.* = .{
            .index = borrowed.index,
            .socket = socket,
            .context = context,
            .type = .{ .recv = buffer },
            .time = null,
        };

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .u64 = borrowed.index },
        };

        epoll.add_fd(socket, &event) catch |e| {
            if (e == error.FileDescriptorAlreadyPresentInSet) {
                epoll.mod_fd(socket, &event) catch unreachable;
            } else unreachable;
        };
    }

    pub fn queue_send(
        self: *Async,
        context: *anyopaque,
        socket: std.posix.socket_t,
        buffer: []const u8,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const borrowed = epoll.jobs.borrow() catch return error.QueueFull;
        borrowed.item.* = .{
            .index = borrowed.index,
            .socket = socket,
            .context = context,
            .type = .{ .send = buffer },
            .time = null,
        };

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.OUT,
            .data = .{ .u64 = borrowed.index },
        };

        epoll.mod_fd(socket, &event) catch unreachable;
    }

    pub fn queue_close(
        self: *Async,
        context: *anyopaque,
        socket: std.posix.socket_t,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const borrowed = epoll.jobs.borrow() catch return error.QueueFull;
        borrowed.item.* = .{
            .index = borrowed.index,
            .socket = socket,
            .context = context,
            .type = .close,
            .time = null,
        };

        epoll.remove_fd(socket) catch unreachable;
    }

    fn add_fd(self: *Self, fd: std.posix.socket_t, event: *std.os.linux.epoll_event) !void {
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, event);
    }

    fn mod_fd(self: *Self, fd: std.posix.socket_t, event: *std.os.linux.epoll_event) !void {
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, event);
    }

    fn remove_fd(self: *Self, fd: std.posix.socket_t) !void {
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
    }

    pub fn submit(self: *Async) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));

        if (epoll.timeout) |_| {
            const ms = std.time.milliTimestamp();
            var iter = epoll.jobs.iterator();
            while (iter.next()) |job| {
                if (job.time == null) job.time = ms;
            }
        }
    }

    pub fn reap(self: *Async) AsyncError![]Completion {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const max_events = @min(epoll.events.len, self.completions.len);
        const timeout: i32 = if (epoll.timeout) |_| 1 else -1;
        var reaped: usize = 0;

        while (reaped < 1) {
            const num_events = std.posix.epoll_wait(epoll.epoll_fd, epoll.events[0..max_events], timeout);

            epoll_loop: for (epoll.events[0..num_events]) |event| {
                const job_index = event.data.u64;
                var job_complete = true;
                assert(epoll.jobs.dirty.isSet(job_index));
                const job = epoll.jobs.items[job_index];

                defer if (job_complete) epoll.jobs.release(job_index);

                const result: Completion.Result = blk: {
                    switch (job.type) {
                        .accept => {
                            assert(event.events & std.os.linux.EPOLL.IN != 0);
                            const accepted_fd = std.posix.accept(job.socket, null, null, 0) catch |e| {
                                switch (e) {
                                    // This is only allowed here because
                                    // multiple threads are sitting on accept.
                                    // Any other case is unreachable.
                                    error.WouldBlock => {
                                        job_complete = false;
                                        continue :epoll_loop;
                                    },
                                    else => {
                                        log.debug("accept failed: {}", .{e});
                                        epoll.remove_fd(job.socket) catch unreachable;
                                        break :blk .{ .socket = -1 };
                                    },
                                }
                            };

                            epoll.remove_fd(job.socket) catch unreachable;
                            break :blk .{ .socket = accepted_fd };
                        },
                        .recv => |buffer| {
                            assert(event.events & std.os.linux.EPOLL.IN != 0);
                            const bytes_read = std.posix.recv(job.socket, buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => unreachable,
                                    error.ConnectionResetByPeer => {
                                        epoll.remove_fd(job.socket) catch unreachable;
                                        break :blk .{ .value = 0 };
                                    },
                                    else => {
                                        log.debug("recv failed: {}", .{e});
                                        epoll.remove_fd(job.socket) catch unreachable;
                                        break :blk .{ .value = -1 };
                                    },
                                }
                            };

                            break :blk .{ .value = @intCast(bytes_read) };
                        },
                        .send => |buffer| {
                            assert(event.events & std.os.linux.EPOLL.OUT != 0);
                            const bytes_sent = std.posix.send(job.socket, buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => unreachable,
                                    error.ConnectionResetByPeer => {
                                        epoll.remove_fd(job.socket) catch unreachable;
                                        break :blk .{ .value = 0 };
                                    },
                                    else => {
                                        log.debug("send failed: {}", .{e});
                                        epoll.remove_fd(job.socket) catch unreachable;
                                        break :blk .{ .value = -1 };
                                    },
                                }
                            };

                            break :blk .{ .value = @intCast(bytes_sent) };
                        },
                        .close => {
                            std.posix.close(job.socket);
                            break :blk .{ .value = 0 };
                        },
                    }
                };

                self.completions[reaped] = .{
                    .result = result,
                    .context = job.context,
                };

                reaped += 1;
            }

            if (epoll.timeout) |timeout_ms| {
                const time = std.time.milliTimestamp();

                var iter = epoll.jobs.iterator();
                while (iter.next()) |job| {
                    if (reaped >= self.completions.len) break;

                    if (time >= job.time.? + timeout_ms) {
                        epoll.remove_fd(job.socket) catch unreachable;
                        epoll.jobs.release(job.index);

                        self.completions[reaped] = .{
                            .result = .timeout,
                            .context = job.context,
                        };

                        reaped += 1;
                    }
                }
            }
        }

        return self.completions[0..reaped];
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
