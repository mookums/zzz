const std = @import("std");

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

    queue_send: *const fn (self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void,
    queue_recv: *const fn (self: *Async, context: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void,
    submit: *const fn (self: *Async) AsyncError!void,
};
