const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Runtime = @import("tardy").Runtime;
const Socket = @import("tardy").Socket;

// Context is dependent on the server that gets created.
pub const Context = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    /// The Request that triggered this handler.
    request: *const Request,
    /// Socket for this Connection.
    socket: Socket,
};
