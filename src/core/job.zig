const std = @import("std");

pub const Job = enum {
    Accept,
    Read,
    Write,
    Close,
};
