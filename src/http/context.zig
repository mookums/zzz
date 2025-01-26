const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Runtime = @import("tardy").Runtime;
const Socket = @import("tardy").Socket;

const Capture = @import("router/routing_trie.zig").Capture;
const QueryMap = @import("router/routing_trie.zig").QueryMap;

// Context is dependent on the server that gets created.
pub const Context = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    /// The Request that triggered this handler.
    request: *const Request,
    response: *Response,
    /// Socket for this Connection.
    socket: Socket,
    captures: []const Capture,
    queries: *const QueryMap,
};
