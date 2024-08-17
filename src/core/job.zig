const std = @import("std");
const Pseudoslice = @import("lib.zig").Pseudoslice;

const JobType = enum {
    Accept,
    Recv,
    Send,
    Close,
};

const ReadJob = union(enum) {
    Header,
    Body: u32,
};

pub const Job = union(JobType) {
    Accept,
    Recv: struct { kind: ReadJob, count: u32 },
    Send: struct { slice: Pseudoslice, count: u32 },
    Close,
};
