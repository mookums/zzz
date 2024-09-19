const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Socket = @import("../core/socket.zig").Socket;
const Completion = @import("completion.zig").Completion;

pub const AsyncType = union(enum) {
    /// Only available on Linux >= 5.1
    io_uring,
    /// Only available on BSD >= 4.1
    //kqueue,
    /// Only available on Windows >= 3.5
    //iocp,
    /// Available on all targets.
    custom: Async,
};

pub const AutoAsyncType = switch (builtin.os.tag) {
    .linux => AsyncType.io_uring,
    .windows => @compileError("iocp not supported yet"),
    .freestanding => @compileError("must provide a custom Async backend"),
    else => if (builtin.os.tag.isBSD()) @compileError("kqueue not supported yet") else @compileError("must provide a custom Async backend"),
};

pub const AsyncError = error{
    QueueFull,
};

pub const Async = struct {
    runner: *anyopaque,
    attached: bool = false,
    completions: []Completion = undefined,

    _queue_accept: *const fn (
        self: *Async,
        context: *anyopaque,
        socket: Socket,
    ) AsyncError!void,

    _queue_recv: *const fn (
        self: *Async,
        context: *anyopaque,
        socket: Socket,
        buffer: []u8,
    ) AsyncError!void,

    _queue_send: *const fn (
        self: *Async,
        context: *anyopaque,
        socket: Socket,
        buffer: []const u8,
    ) AsyncError!void,

    _queue_close: *const fn (
        self: *Async,
        context: *anyopaque,
        fd: std.posix.fd_t,
    ) AsyncError!void,

    _reap: *const fn (self: *Async) AsyncError![]Completion,
    _submit: *const fn (self: *Async) AsyncError!void,

    /// This provides the completions that the backend will utilize when
    /// submitting and reaping. This MUST be called before any other
    /// methods on this Async instance.
    pub fn attach(self: *Async, completions: []Completion) void {
        self.completions = completions;
        self.attached = true;
    }

    pub fn queue_accept(
        self: *Async,
        context: *anyopaque,
        socket: Socket,
    ) AsyncError!void {
        assert(self.attached);
        try @call(.auto, self._queue_accept, .{ self, context, socket });
    }

    pub fn queue_recv(
        self: *Async,
        context: *anyopaque,
        socket: Socket,
        buffer: []u8,
    ) AsyncError!void {
        assert(self.attached);
        try @call(.auto, self._queue_recv, .{ self, context, socket, buffer });
    }

    pub fn queue_send(
        self: *Async,
        context: *anyopaque,
        socket: Socket,
        buffer: []const u8,
    ) AsyncError!void {
        assert(self.attached);
        try @call(.auto, self._queue_send, .{ self, context, socket, buffer });
    }

    pub fn queue_close(
        self: *Async,
        context: *anyopaque,
        socket: Socket,
    ) AsyncError!void {
        assert(self.attached);
        try @call(.auto, self._queue_close, .{ self, context, socket });
    }

    pub fn reap(self: *Async) AsyncError![]Completion {
        assert(self.attached);
        return try @call(.auto, self._reap, .{self});
    }

    pub fn submit(self: *Async) AsyncError!void {
        assert(self.attached);
        try @call(.auto, self._submit, .{self});
    }
};
