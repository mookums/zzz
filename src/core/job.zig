const std = @import("std");
const Pseudoslice = @import("lib.zig").Pseudoslice;

const JobType = enum {
    open,
    read,
    write,
    accept,
    recv,
    send,
    close,
};

pub const SendType = union(enum) {
    plain: struct {
        slice: Pseudoslice,
        count: u32,
    },
    tls: struct {
        slice: Pseudoslice,
        count: u32,
        encrypted: []const u8,
        encrypted_count: u32,
    },
};

pub const Job = union(JobType) {
    open,
    read: struct { fd: std.posix.fd_t, count: u32 },
    write: struct { fd: std.posix.fd_t, count: u32 },
    accept,
    recv: struct { count: u32 },
    send: SendType,
    close,
};
