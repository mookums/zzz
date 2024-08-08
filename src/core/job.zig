const std = @import("std");

const JobType = enum {
    Accept,
    Read,
    Write,
    Close,
};

const Read = struct {
    socket: std.posix.socket_t,
    arena: *std.heap.ArenaAllocator,
    buffer: []u8,
    request: *std.ArrayList(u8),
};

const Write = struct {
    socket: std.posix.socket_t,
    arena: *std.heap.ArenaAllocator,
    response: []const u8,
    write_count: i32,
};

pub const Job = union(JobType) {
    Accept,
    Read: Read,
    Write: Write,
    Close,
};
