const std = @import("std");
const Pseudoslice = @import("lib.zig").Pseudoslice;

const JobType = enum {
    Open,
    Read,
    Write,
    Accept,
    Recv,
    Send,
    Close,
};

pub const SendType = union(enum) {
    Plain: struct {
        slice: Pseudoslice,
        count: u32,
    },
    TLS: struct {
        slice: Pseudoslice,
        count: u32,
        encrypted: []const u8,
        encrypted_count: u32,
    },
};

pub const Job = union(JobType) {
    Open,
    Read: struct { fd: std.posix.fd_t, count: u32 },
    Write: struct { fd: std.posix.fd_t, count: u32 },
    Accept,
    Recv: struct { count: u32 },
    Send: SendType,
    Close,
};
