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
    timespec: ?std.os.linux.itimerspec,

    const Job = struct {
        type: union(enum) {
            accept,
            recv: []u8,
            send: []const u8,
            close,
            timer: struct { fd: i32, index: usize },
        },
        timer_index: ?usize = null,
        index: usize,
        fd: std.posix.fd_t,
        context: *anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !Self {
        const epoll_fd = try std.posix.epoll_create1(0);
        assert(epoll_fd > -1);
        errdefer std.posix.close(epoll_fd);

        const size = blk: {
            if (options.ms_operation_max) |_| {
                break :blk options.size_connections_max * 2;
            } else {
                break :blk options.size_connections_max;
            }
        };

        const events = try allocator.alloc(std.os.linux.epoll_event, size);
        errdefer allocator.free(events);

        const jobs = try Pool(Job).init(allocator, size, null, null);
        errdefer jobs.deinit();

        const timespec: ?std.os.linux.itimerspec = blk: {
            if (options.ms_operation_max) |ms| {
                break :blk std.os.linux.itimerspec{
                    .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
                    .it_value = .{
                        .tv_sec = @divFloor(ms, std.time.ms_per_s),
                        .tv_nsec = @rem(ms, std.time.ms_per_s) * std.time.ns_per_ms,
                    },
                };
            } else {
                break :blk null;
            }
        };

        return Self{
            .epoll_fd = epoll_fd,
            .events = events,
            .jobs = jobs,
            .timespec = timespec,
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
        fd: std.posix.fd_t,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const borrowed = epoll.jobs.borrow(@intCast(fd)) catch return error.QueueFull;
        borrowed.item.* = .{
            .index = borrowed.index,
            .fd = fd,
            .context = context,
            .type = .accept,
        };

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN | std.os.linux.EPOLL.EXCLUSIVE,
            .data = .{ .u64 = borrowed.index },
        };

        epoll.add_fd(fd, &event) catch unreachable;

        if (epoll.timespec) |*ts| {
            const timer: i32 = @intCast(std.os.linux.timerfd_create(
                std.os.linux.CLOCK.BOOTTIME,
                .{ .NONBLOCK = true },
            ));
            _ = std.os.linux.timerfd_settime(timer, .{}, ts, null);

            const timer_borrowed = epoll.jobs.borrow(@intCast(timer)) catch return error.QueueFull;
            timer_borrowed.item.* = .{
                .index = timer_borrowed.index,
                .fd = fd,
                .context = context,
                .type = .{ .timer = .{ .index = borrowed.index, .fd = timer } },
            };

            var timer_event: std.os.linux.epoll_event = .{
                .events = std.os.linux.EPOLL.IN,
                .data = .{ .u64 = timer_borrowed.index },
            };

            epoll.jobs.items[borrowed.index].timer_index = timer_borrowed.index;
            epoll.add_fd(timer, &timer_event) catch unreachable;
        }
    }

    pub fn queue_recv(
        self: *Async,
        context: *anyopaque,
        fd: std.posix.fd_t,
        buffer: []u8,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const borrowed = epoll.jobs.borrow(@intCast(fd)) catch return error.QueueFull;
        borrowed.item.* = .{
            .index = borrowed.index,
            .fd = fd,
            .context = context,
            .type = .{ .recv = buffer },
        };

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.IN,
            .data = .{ .u64 = borrowed.index },
        };

        epoll.add_fd(fd, &event) catch |e| {
            if (e == error.FileDescriptorAlreadyPresentInSet) {
                epoll.mod_fd(fd, &event) catch unreachable;
            } else unreachable;
        };

        if (epoll.timespec) |*ts| {
            const timer: i32 = @intCast(std.os.linux.timerfd_create(
                std.os.linux.CLOCK.BOOTTIME,
                .{ .NONBLOCK = true },
            ));
            _ = std.os.linux.timerfd_settime(timer, .{}, ts, null);

            const timer_borrowed = epoll.jobs.borrow(@intCast(timer)) catch return error.QueueFull;
            timer_borrowed.item.* = .{
                .index = timer_borrowed.index,
                .fd = fd,
                .context = context,
                .type = .{ .timer = .{ .index = borrowed.index, .fd = timer } },
            };

            var timer_event: std.os.linux.epoll_event = .{
                .events = std.os.linux.EPOLL.IN,
                .data = .{ .u64 = timer_borrowed.index },
            };

            epoll.jobs.items[borrowed.index].timer_index = timer_borrowed.index;
            epoll.add_fd(timer, &timer_event) catch unreachable;
        }
    }

    pub fn queue_send(
        self: *Async,
        context: *anyopaque,
        fd: std.posix.fd_t,
        buffer: []const u8,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const borrowed = epoll.jobs.borrow(@intCast(fd)) catch return error.QueueFull;
        borrowed.item.* = .{
            .index = borrowed.index,
            .fd = fd,
            .context = context,
            .type = .{ .send = buffer },
        };

        var event: std.os.linux.epoll_event = .{
            .events = std.os.linux.EPOLL.OUT,
            .data = .{ .u64 = borrowed.index },
        };

        epoll.mod_fd(fd, &event) catch unreachable;

        if (epoll.timespec) |*ts| {
            const timer: i32 = @intCast(std.os.linux.timerfd_create(
                std.os.linux.CLOCK.BOOTTIME,
                .{ .NONBLOCK = true },
            ));
            _ = std.os.linux.timerfd_settime(timer, .{}, ts, null);

            const timer_borrowed = epoll.jobs.borrow(@intCast(timer)) catch return error.QueueFull;
            timer_borrowed.item.* = .{
                .index = timer_borrowed.index,
                .fd = fd,
                .context = context,
                .type = .{ .timer = .{ .index = borrowed.index, .fd = timer } },
            };

            var timer_event: std.os.linux.epoll_event = .{
                .events = std.os.linux.EPOLL.IN,
                .data = .{ .u64 = timer_borrowed.index },
            };

            epoll.jobs.items[borrowed.index].timer_index = timer_borrowed.index;
            epoll.add_fd(timer, &timer_event) catch unreachable;
        }
    }

    pub fn queue_close(
        self: *Async,
        context: *anyopaque,
        fd: std.posix.fd_t,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const borrowed = epoll.jobs.borrow(@intCast(fd)) catch return error.QueueFull;
        borrowed.item.* = .{
            .index = borrowed.index,
            .fd = fd,
            .context = context,
            .type = .close,
        };

        epoll.remove_fd(fd) catch unreachable;
    }

    fn add_fd(self: *Self, fd: std.posix.fd_t, event: *std.os.linux.epoll_event) !void {
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, event);
    }

    fn mod_fd(self: *Self, fd: std.posix.fd_t, event: *std.os.linux.epoll_event) !void {
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, event);
    }

    fn remove_fd(self: *Self, fd: std.posix.fd_t) !void {
        try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
    }

    pub fn submit(self: *Async) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        _ = epoll;
    }

    pub fn reap(self: *Async) AsyncError![]Completion {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const max_events = @min(epoll.events.len, self.completions.len);
        const timeout: i32 = -1;
        var reaped: usize = 0;

        while (reaped < 1) {
            const num_events = std.posix.epoll_wait(epoll.epoll_fd, epoll.events[0..max_events], timeout);
            log.debug("Number of Events: {d}", .{num_events});
            log.debug("Number of slots in Pool: {d}", .{epoll.jobs.items.len - epoll.jobs.dirty.count()});

            for (epoll.events[0..num_events]) |event| {
                const job_index = event.data.u64;
                const job = epoll.jobs.items[job_index];
                log.debug("Event Job: {s}", .{@tagName(job.type)});
            }

            epoll_loop: for (epoll.events[0..num_events]) |event| {
                const job_index = event.data.u64;
                var job_complete = true;
                assert(epoll.jobs.dirty.isSet(job_index));
                const job = epoll.jobs.items[job_index];

                defer if (job_complete) {
                    epoll.jobs.release(job_index);

                    if (epoll.timespec != null) {
                        if (job.type != .timer) {
                            assert(job.timer_index != null);
                            const timer_job = &epoll.jobs.items[job.timer_index.?];
                            assert(timer_job.type == .timer);
                            const info = timer_job.type.timer;
                            timer_job.fd = info.fd;

                            // cancel the timeout.
                            epoll.remove_fd(timer_job.fd) catch unreachable;
                            std.posix.close(timer_job.fd);
                            epoll.jobs.release(timer_job.index);
                        }
                    }
                };

                const result: Completion.Result = blk: {
                    switch (job.type) {
                        .timer => |inner| {
                            assert(event.events & std.os.linux.EPOLL.IN != 0);

                            {
                                var timer_buf = [_]u8{undefined} ** 8;
                                _ = std.posix.read(inner.fd, timer_buf[0..]) catch |e| {
                                    switch (e) {
                                        error.WouldBlock => unreachable,
                                        else => {},
                                    }
                                };
                            }

                            const linked_job = &epoll.jobs.items[inner.index];

                            // remove and close timer.
                            epoll.remove_fd(inner.fd) catch unreachable;
                            std.posix.close(inner.fd);

                            // cancel linked job
                            epoll.remove_fd(linked_job.fd) catch unreachable;
                            epoll.jobs.release(linked_job.index);

                            break :blk .timeout;
                        },
                        .accept => {
                            assert(event.events & std.os.linux.EPOLL.IN != 0);
                            const accepted_fd = std.posix.accept(job.fd, null, null, 0) catch |e| {
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
                                        epoll.remove_fd(job.fd) catch unreachable;
                                        break :blk .{ .socket = -1 };
                                    },
                                }
                            };

                            epoll.remove_fd(job.fd) catch unreachable;
                            break :blk .{ .socket = accepted_fd };
                        },
                        .recv => |buffer| {
                            assert(event.events & std.os.linux.EPOLL.IN != 0);
                            const bytes_read = std.posix.recv(job.fd, buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => unreachable,
                                    error.ConnectionResetByPeer => {
                                        epoll.remove_fd(job.fd) catch unreachable;
                                        break :blk .{ .value = 0 };
                                    },
                                    else => {
                                        log.debug("recv failed: {}", .{e});
                                        epoll.remove_fd(job.fd) catch unreachable;
                                        break :blk .{ .value = -1 };
                                    },
                                }
                            };

                            break :blk .{ .value = @intCast(bytes_read) };
                        },
                        .send => |buffer| {
                            assert(event.events & std.os.linux.EPOLL.OUT != 0);
                            const bytes_sent = std.posix.send(job.fd, buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => unreachable,
                                    error.ConnectionResetByPeer => {
                                        epoll.remove_fd(job.fd) catch unreachable;
                                        break :blk .{ .value = 0 };
                                    },
                                    else => {
                                        log.debug("send failed: {}", .{e});
                                        epoll.remove_fd(job.fd) catch unreachable;
                                        break :blk .{ .value = -1 };
                                    },
                                }
                            };

                            break :blk .{ .value = @intCast(bytes_sent) };
                        },
                        .close => {
                            std.posix.close(job.fd);
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
