const std = @import("std");

const CompletionResult = union {
    socket: std.posix.socket_t,
    result: i32,
};

pub const Completion = struct {
    context: *anyopaque,
    result: i32,
};
