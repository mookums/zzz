const std = @import("std");

const UringJobType = enum {
    Accept,
    Read,
    Write,
    Close,
};

const UringAccept = struct {
    allocator: *std.mem.Allocator,
};

const UringRead = struct {
    allocator: *std.mem.Allocator,
    socket: std.posix.socket_t,
    buffer: []u8,
    request: *std.ArrayList(u8),
};

const UringWrite = struct {
    allocator: *std.mem.Allocator,
    socket: std.posix.socket_t,
    response: []u8,
    write_count: i32,
};

const UringClose = struct {
    allocator: *std.mem.Allocator,
};

pub const UringJob = union(UringJobType) {
    Accept: UringAccept,
    Read: UringRead,
    Write: UringWrite,
    Close: UringClose,
};
