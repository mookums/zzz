const std = @import("std");

// This should be the TCP Server interface that all TCP based protocol servers use.
pub const TCPProtocol = struct {
    allocator: std.mem.Allocator,
    context: *anyopaque,
    accept: *const fn (ctx: anytype) void,
    read: *const fn (ctx: anytype) void,
    write: *const fn (ctx: anytype) void,
    close: *const fn (ctx: anytype) void,
};

// We should probably move the TCP event loop up to here?
// and then just have HTTP implement this interface.
//
// So this interface needs to be platform-independent. It should literally JUST be the protocol.
// This is because the loop here may be:
// io_uring | epoll -> linux
// kqueue -> bsd
// iocp -> windows
// custom (maybe)
pub const HTTP = @import("http/server.zig");
