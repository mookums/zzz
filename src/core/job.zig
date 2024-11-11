const std = @import("std");
const Pseudoslice = @import("lib.zig").Pseudoslice;

const TaskFn = @import("tardy").TaskFn;

pub const AfterType = union(enum) {
    recv,
    sse: struct {
        func: *const anyopaque,
        ctx: *anyopaque,
    },
};
pub const SendInner = struct {
    after: AfterType,
    slice: Pseudoslice,
    count: usize,
    security: union(enum) {
        plain,
        tls: struct {
            encrypted: []const u8,
            encrypted_count: usize,
        },
    },
};

pub const Job = union(enum) {
    /// This is the status for all jobs
    /// that are empty. They do nothing and are
    /// ready to be utilized.
    empty,
    open,
    read: struct { fd: std.posix.fd_t, count: usize },
    write: struct { fd: std.posix.fd_t, count: usize },
    accept,
    handshake: struct { state: enum { recv, send }, count: usize },
    recv: struct { count: usize },
    send: SendInner,
    close,
};
