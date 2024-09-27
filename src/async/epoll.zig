const std = @import("std");
const assert = std.debug.assert;
const Completion = @import("completion.zig").Completion;
const Async = @import("lib.zig").Async;
const AsyncError = @import("lib.zig").AsyncError;
const AsyncOptions = @import("lib.zig").AsyncOptions;

const log = std.log.scoped(.@"zzz/async/epoll");

pub const AsyncEpoll = struct {
    const Self = @This();

    epoll_fd: std.posix.fd_t,
    events: []std.os.linux.epoll_event,
    queued_jobs: std.ArrayList(Job),

    const Job = union(enum) {
        accept: struct { socket: std.posix.socket_t, context: *anyopaque },
        recv: struct { socket: std.posix.socket_t, context: *anyopaque, buffer: []u8 },
        send: struct { socket: std.posix.socket_t, context: *anyopaque, buffer: []const u8 },
        close: struct { socket: std.posix.socket_t, context: *anyopaque },
    };

    pub fn init(allocator: std.mem.Allocator, options: AsyncOptions) !Self {
        const epoll_fd = try std.posix.epoll_create1(0);
        assert(epoll_fd > -1);
        errdefer std.posix.close(epoll_fd);

        const events = try allocator.alloc(std.os.linux.epoll_event, options.size_connections_max);
        errdefer allocator.free(events);

        const jobs = try std.ArrayList(Job).initCapacity(allocator, options.size_connections_max);
        errdefer jobs.deinit();

        return Self{
            .epoll_fd = epoll_fd,
            .events = events,
            .queued_jobs = jobs,
        };
    }

    pub fn deinit(self: *Async, allocator: std.mem.Allocator) void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        std.posix.close(epoll.epoll_fd);
        allocator.free(epoll.events);
        epoll.queued_jobs.deinit();
    }

    pub fn queue_accept(
        self: *Async,
        context: *anyopaque,
        socket: std.posix.socket_t,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        epoll.queued_jobs.appendAssumeCapacity(.{ .accept = .{
            .socket = socket,
            .context = context,
        } });
    }

    pub fn queue_recv(
        self: *Async,
        context: *anyopaque,
        socket: std.posix.socket_t,
        buffer: []u8,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        epoll.queued_jobs.appendAssumeCapacity(.{ .recv = .{
            .socket = socket,
            .context = context,
            .buffer = buffer,
        } });
    }

    pub fn queue_send(
        self: *Async,
        context: *anyopaque,
        socket: std.posix.socket_t,
        buffer: []const u8,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        epoll.queued_jobs.appendAssumeCapacity(.{ .send = .{
            .socket = socket,
            .context = context,
            .buffer = buffer,
        } });
    }

    pub fn queue_close(
        self: *Async,
        context: *anyopaque,
        socket: std.posix.socket_t,
    ) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        epoll.queued_jobs.appendAssumeCapacity(.{ .close = .{
            .socket = socket,
            .context = context,
        } });
    }

    fn add_or_mod_fd(self: *Self, fd: std.posix.fd_t, event: *std.os.linux.epoll_event) !void {
        std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_ADD, fd, event) catch |err| {
            if (err == error.FileDescriptorAlreadyPresentInSet) {
                try std.posix.epoll_ctl(self.epoll_fd, std.os.linux.EPOLL.CTL_MOD, fd, event);
            } else {
                return err;
            }
        };
    }

    pub fn submit(self: *Async) AsyncError!void {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        for (epoll.queued_jobs.items) |job| {
            var event = std.os.linux.epoll_event{
                .events = switch (job) {
                    .accept, .recv => std.os.linux.EPOLL.IN,
                    .send => std.os.linux.EPOLL.OUT,
                    .close => unreachable,
                },
                .data = .{ .ptr = switch (job) {
                    .accept => |j| @intFromPtr(j.context),
                    .recv => |j| @intFromPtr(j.context),
                    .send => |j| @intFromPtr(j.context),
                    .close => unreachable,
                } },
            };

            const socket = switch (job) {
                .accept => |j| j.socket,
                .recv => |j| j.socket,
                .send => |j| j.socket,
                .close => |j| j.socket,
            };

            if (job == .close) {
                _ = std.posix.epoll_ctl(epoll.epoll_fd, std.os.linux.EPOLL.CTL_DEL, socket, null) catch {};
            } else {
                epoll.add_or_mod_fd(socket, &event) catch unreachable;
            }
        }
    }

    pub fn reap(self: *Async) AsyncError![]Completion {
        const epoll: *Self = @ptrCast(@alignCast(self.runner));
        const max_events = @min(epoll.events.len, self.completions.len);
        const timeout: i32 = -1;
        var reaped: usize = 0;

        while (reaped < 1) {
            const num_events = std.posix.epoll_wait(epoll.epoll_fd, epoll.events[0..max_events], timeout);

            epoll_loop: for (epoll.events[0..num_events]) |event| {
                const context: *anyopaque = @ptrFromInt(event.data.ptr);
                var result: Completion.Result = undefined;

                // Find the corresponding job
                const job_index = for (epoll.queued_jobs.items, 0..) |job, i| {
                    switch (job) {
                        .accept => |accept_job| if (accept_job.context == context) break i,
                        .recv => |recv_job| if (recv_job.context == context) break i,
                        .send => |send_job| if (send_job.context == context) break i,
                        .close => |close_job| if (close_job.context == context) break i,
                    }
                } else {
                    log.warn("No matching job found for event", .{});
                    continue :epoll_loop;
                };

                const job = epoll.queued_jobs.swapRemove(job_index);

                switch (job) {
                    .accept => |accept_job| {
                        if (event.events & std.os.linux.EPOLL.IN != 0) {
                            const accepted_socket = std.posix.accept(accept_job.socket, null, null, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => {
                                        epoll.queued_jobs.appendAssumeCapacity(job);
                                        continue :epoll_loop;
                                    },
                                    else => {
                                        log.debug("accept failed: {}", .{e});
                                        result = .{ .value = -1 };
                                        break;
                                    },
                                }
                            };
                            result = .{ .socket = accepted_socket };
                        } else continue :epoll_loop;
                    },
                    .recv => |recv_job| {
                        if (event.events & std.os.linux.EPOLL.IN != 0) {
                            const bytes_read = std.posix.recv(recv_job.socket, recv_job.buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => {
                                        epoll.queued_jobs.appendAssumeCapacity(job);
                                        continue :epoll_loop;
                                    },
                                    else => {
                                        log.debug("recv failed: {}", .{e});
                                        result = .{ .value = -1 };
                                        break;
                                    },
                                }
                            };
                            result = .{ .value = @intCast(bytes_read) };
                        } else continue :epoll_loop;
                    },
                    .send => |send_job| {
                        if (event.events & std.os.linux.EPOLL.OUT != 0) {
                            const bytes_sent = std.posix.send(send_job.socket, send_job.buffer, 0) catch |e| {
                                switch (e) {
                                    error.WouldBlock => {
                                        epoll.queued_jobs.appendAssumeCapacity(job);
                                        continue :epoll_loop;
                                    },
                                    else => {
                                        log.debug("send failed: {}", .{e});
                                        result = .{ .value = -1 };
                                        break;
                                    },
                                }
                            };
                            result = .{ .value = @intCast(bytes_sent) };
                        } else continue :epoll_loop;
                    },
                    .close => |close_job| {
                        std.posix.close(close_job.socket);
                        result = .{ .value = 0 };
                    },
                }

                self.completions[reaped] = .{
                    .result = result,
                    .context = context,
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
