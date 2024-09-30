const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Socket = @import("../core/socket.zig").Socket;
const Completion = @import("completion.zig").Completion;

pub const AsyncType = union(enum) {
    /// Attempts to automatically match
    /// the best backend.
    ///
    /// `Linux: io_uring -> epoll -> busy_loop
    /// Windows: busy_loop
    /// Darwin & BSD: busy_loop
    /// Solaris: busy_loop`
    auto,
    /// Only available on Linux >= 5.1
    ///
    /// Utilizes the io_uring interface for handling I/O.
    /// `https://kernel.dk/io_uring.pdf`
    io_uring,
    /// Only available on Linux >= 2.5.45
    ///
    /// Utilizes the epoll interface for handling I/O.
    epoll,
    /// Available on most targets.
    /// Relies on non-blocking sockets and busy loop polling.
    busy_loop,
    /// Available on all targets.
    custom: type,
};

pub fn auto_async_match() AsyncType {
    switch (comptime builtin.target.os.tag) {
        .linux => {
            const version = comptime builtin.target.os.getVersionRange().linux;

            if (version.isAtLeast(.{
                .major = 5,
                .minor = 1,
                .patch = 0,
            }) orelse @compileError("Unable to determine kernel version. Specify an Async Backend.")) {
                return AsyncType.io_uring;
            }

            if (version.isAtLeast(.{
                .major = 2,
                .minor = 5,
                .patch = 45,
            }) orelse @compileError("Unable to determine kernel version. Specify an Async Backend.")) {
                return AsyncType.epoll;
            }

            return AsyncType.busy_loop;
        },
        .windows => return AsyncType.busy_loop,
        .ios, .macos, .watchos, .tvos, .visionos => return AsyncType.busy_loop,
        .kfreebsd, .freebsd, .openbsd, .netbsd, .dragonfly => return AsyncType.busy_loop,
        .solaris, .illumos => return AsyncType.busy_loop,
        else => @compileError("Unsupported platform! Provide a custom Async backend."),
    }
}

pub const AsyncError = error{
    QueueFull,
};

pub const AsyncOptions = struct {
    /// The root Async that this should inherit
    /// parameters from. This is useful for io_uring.
    root_async: ?Async = null,
    /// Is this Async instance spawning within a thread?
    in_thread: bool = false,
    /// Maximum number of connections for this backend.
    size_connections_max: u16,
    /// Maximum length of time before operation is timed out.
    /// null if no timeout
    ms_operation_max: ?u32,
};

pub const Async = struct {
    runner: *anyopaque,
    attached: bool = false,
    completions: []Completion = undefined,

    _deinit: *const fn (
        self: *Async,
        allocator: std.mem.Allocator,
    ) void,

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

    pub fn deinit(
        self: *Async,
        allocator: std.mem.Allocator,
    ) void {
        @call(.auto, self._deinit, .{ self, allocator });
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
