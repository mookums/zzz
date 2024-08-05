const std = @import("std");

const UringJobType = enum {
    Accept,
    Read,
    Write,
    Close,
};

const UringRead = struct {
    socket: std.posix.socket_t,
    buffer: []u8,
    request: *std.ArrayList(u8),
};

const UringWrite = struct {
    socket: std.posix.socket_t,
    response: []const u8,
    write_count: i32,
};

pub const UringJob = union(UringJobType) {
    Accept,
    Read: UringRead,
    Write: UringWrite,
    Close,
};
