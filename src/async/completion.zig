const std = @import("std");

pub const Completion = struct {
    pub const Result = union {
        socket: std.posix.socket_t,
        value: i32,
    };

    context: *anyopaque,
    result: Result,
};
