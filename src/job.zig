const std = @import("std");
const xev = @import("xev");

const RequestContext = @import("main.zig").RequestContext;

const AcceptJob = struct {
    server: std.net.Server,
};

const ReadJob = struct {
    stream: std.net.Stream,
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

const NewReadJob = struct {
    // Needed for scheduling new async io.
    loop: *xev.Loop,
    context: *RequestContext,
    tcp: xev.TCP,
    buffer: []const u8,
};

const Jobs = enum {
    Accept,
    Read,
    Respond,
    Close,
    Noop,
    Abort,
    NewRead,
};

pub const Job = union(Jobs) {
    Accept: AcceptJob,
    Read: ReadJob,
    Respond: RespondJob,
    Close: CloseJob,
    Noop: NoopJob,
    Abort: AbortJob,
    NewRead: NewReadJob,
};
