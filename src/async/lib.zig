const std = @import("std");
const Completion = @import("completion.zig").Completion;

pub const AsyncType = enum {
    /// Only available on Linux >= 5.1
    /// Preferred on Linux over epoll.
    io_uring,
    /// Only available on BSD >= 4.1
    kqueue,
    /// Only available on Windows >= 3.5
    iocp,
    /// Available on all targets.
    custom,
};

pub const AsyncError = error{};

pub const Async = struct {
    runner: *anyopaque,
    completions: [256]Completion,

    _queue_accept: *const fn (self: *Async, context: *anyopaque, socket: std.posix.socket_t) AsyncError!void,
    _queue_send: *const fn (self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []const u8) AsyncError!void,
    _queue_recv: *const fn (self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void,
    _reap: *const fn (self: *Async) AsyncError![]Completion,
    _submit: *const fn (self: *Async) AsyncError!void,

    pub fn queue_accept(self: *Async, context: *anyopaque, socket: std.posix.socket_t) AsyncError!void {
        @call(.auto, self._queue_accept, .{ self, context, socket }) catch unreachable;
    }

    pub fn queue_send(self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []const u8) AsyncError!void {
        @call(.auto, self._queue_send, .{ self, context, socket, buffer }) catch unreachable;
    }

    pub fn queue_recv(self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void {
        @call(.auto, self._queue_recv, .{ self, context, socket, buffer }) catch unreachable;
    }

    pub fn reap(self: *Async) AsyncError![]Completion {
        return @call(.auto, self._reap, .{self}) catch unreachable;
    }

    pub fn submit(self: *Async) AsyncError!void {
        @call(.auto, self._submit, .{self}) catch unreachable;
    }
};
