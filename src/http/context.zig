const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Runtime = @import("tardy").Runtime;
const SecureSocket = @import("../core/secure_socket.zig").SecureSocket;

const Capture = @import("router/routing_trie.zig").Capture;
const AnyCaseStringMap = @import("../core/any_case_string_map.zig").AnyCaseStringMap;

// Context is dependent on the server that gets created.
pub const Context = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    buffer: []u8,
    runtime: *Runtime,
    /// The Request that triggered this handler.
    request: *const Request,
    response: *Response,
    /// Socket for this Connection.
    socket: SecureSocket,
    captures: []const Capture,
    queries: *const AnyCaseStringMap,
};
