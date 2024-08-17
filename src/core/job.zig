const std = @import("std");
const Pseudoslice = @import("lib.zig").Pseudoslice;

const JobType = enum {
    Accept,
    Read,
    Write,
    Close,
};

const ReadJob = enum {
    Header,
    Body,
};

pub const Job = union(JobType) {
    Accept,
    Read: ReadJob,
    Write: struct { slice: Pseudoslice, count: u32 },
    Close,
};
