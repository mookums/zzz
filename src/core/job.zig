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

const RecvJob = union(enum) {
    Header,
    Body: u32,
};

pub const Job = union(JobType) {
    Open,
    Read: struct { fd: std.posix.fd_t, count: u32 },
    Write: struct { fd: std.posix.fd_t, count: u32 },
    Accept,
    Recv: struct { kind: RecvJob, count: u32 },
    Send: struct { slice: Pseudoslice, count: u32 },
    Close,
};
