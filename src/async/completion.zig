const std = @import("std");

pub const Completion = struct {
    pub const Result = union(enum) {
        /// If the request has been canceled.
        canceled,
        /// If the request has timed out.
        timeout,
        /// If we have returned a socket.
        socket: std.posix.socket_t,
        /// If we have returned a value.
        value: i32,
    };

    context: *anyopaque,
    result: Result,
};
