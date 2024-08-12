const std = @import("std");

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
    Write,
    Close,
};
