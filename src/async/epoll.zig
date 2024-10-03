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
        },
        socket: std.posix.socket_t,
        context: *anyopaque,
    };

    pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !Self {
        const epoll_fd = try std.posix.epoll_create1(0);
        assert(epoll_fd > -1);
        errdefer std.posix.close(epoll_fd);

        const events = try allocator.alloc(std.os.linux.epoll_event, options.size_connections_max);
        errdefer allocator.free(events);

        const jobs = try Pool(Job).init(allocator, options.size_connections_max, null, null);
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
        socket: std.posix.socket_t,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const borrowed = epoll.jobs.borrow(@intCast(socket)) catch return error.QueueFull;
        borrowed.item.* = .{
            .socket = socket,
            .context = context,
            .type = .accept,
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
        const borrowed = epoll.jobs.borrow(@intCast(socket)) catch return error.QueueFull;
        borrowed.item.* = .{
            .socket = socket,
            .context = context,
            .type = .{ .recv = buffer },
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
        const borrowed = epoll.jobs.borrow(@intCast(socket)) catch return error.QueueFull;
        borrowed.item.* = .{
            .socket = socket,
            .context = context,
            .type = .{ .send = buffer },
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
        const borrowed = epoll.jobs.borrow(@intCast(socket)) catch return error.QueueFull;
        borrowed.item.* = .{
            .socket = socket,
            .context = context,
            .type = .close,
        };

        epoll.remove_fd(socket) catch unreachable;
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

    fn is_fd_in_epoll(self: *Self, fd: std.posix.fd_t) bool {
        var dummy_event = std.os.linux.epoll_event{
            .events = 0,
            .data = .{ .ptr = 0 },
        };
        std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, &dummy_event) catch |err| {
            return err != error.FileDescriptorNotRegistered;
        };

        return true;
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

            for (epoll.events[0..num_events]) |event| {
                var release_job = true;
                const job_index = event.data.u64;
                defer if (release_job) epoll.jobs.release(job_index);
                assert(epoll.jobs.dirty.isSet(job_index));

                var result: Completion.Result = undefined;
                const job = epoll.jobs.items[job_index];

                switch (job.type) {
                    .accept => {
                        assert(event.events & std.os.linux.EPOLL.IN != 0);
                        const accepted_socket = std.posix.accept(job.socket, null, null, 0) catch |e| {
                            switch (e) {
                                // This is only allowed here because
                                // multiple threads are sitting on accept.
                                // Any other case is unreachable.
                                error.WouldBlock => {
                                    release_job = false;
                                    continue;
                                },
                                else => {
                                    log.debug("accept failed: {}", .{e});
                                    result = .{ .value = -1 };
                                    epoll.remove_fd(job.socket) catch unreachable;
                                    break;
                                },
                            }
                        };

                        result = .{ .socket = accepted_socket };
                        epoll.remove_fd(job.socket) catch unreachable;
                    },
                    .recv => |buffer| {
                        assert(event.events & std.os.linux.EPOLL.IN != 0);
                        const bytes_read = std.posix.recv(job.socket, buffer, 0) catch |e| {
                            switch (e) {
                                error.WouldBlock => unreachable,
                                error.ConnectionResetByPeer => {
                                    result = .{ .value = 0 };
                                    epoll.remove_fd(job.socket) catch unreachable;
                                    break;
                                },
                                else => {
                                    log.debug("recv failed: {}", .{e});
                                    result = .{ .value = -1 };
                                    epoll.remove_fd(job.socket) catch unreachable;
                                    break;
                                },
                            }
                        };

                        result = .{ .value = @intCast(bytes_read) };
                    },
                    .send => |buffer| {
                        assert(event.events & std.os.linux.EPOLL.OUT != 0);
                        const bytes_sent = std.posix.send(job.socket, buffer, 0) catch |e| {
                            switch (e) {
                                error.WouldBlock => unreachable,
                                error.ConnectionResetByPeer => {
                                    result = .{ .value = 0 };
                                    epoll.remove_fd(job.socket) catch unreachable;
                                    break;
                                },
                                else => {
                                    log.debug("send failed: {}", .{e});
                                    result = .{ .value = -1 };
                                    epoll.remove_fd(job.socket) catch unreachable;
                                    break;
                                },
                            }
                        };

                        result = .{ .value = @intCast(bytes_sent) };
                    },
                    .close => {
                        std.posix.close(job.socket);
                        result = .{ .value = 0 };
                    },
                }

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
