const std = @import("std");

const AcceptJob = struct {
    server: std.net.Server,
};

const ReadJob = struct {
    connection: std.net.Server.Connection,
};

const RespondJob = struct {
    stream: std.net.Stream,
    request: []const u8,
};

const CloseJob = struct {
    stream: std.net.Stream,
};

const NoopJob = struct {};

const AbortJob = struct {};

const Jobs = enum {
    Accept,
    Read,
    Respond,
    Close,
    Noop,
    Abort,
};

pub const Job = union(Jobs) {
    Accept: AcceptJob,
    Read: ReadJob,
    Respond: RespondJob,
    Close: CloseJob,
    Noop: NoopJob,
    Abort: AbortJob,
};
