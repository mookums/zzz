const std = @import("std");
const Pseudoslice = @import("lib.zig").Pseudoslice;

const JobType = enum {
    Accept,
    Read,
    Write,
    Close,
};

const ReadJob = union(enum) {
    Header,
    Body: u32,
};

pub const Job = union(JobType) {
    Accept,
    Read: struct { kind: ReadJob, count: u32 },
    Write: struct { slice: Pseudoslice, count: u32 },
    Close,
};
