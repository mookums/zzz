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
    /// Not safe to access unless you are manually sending the headers
    /// and returning the .responded variant of Respond.
    header_buffer: *std.ArrayList(u8),
    runtime: *Runtime,
    /// The Request that triggered this handler.
    request: *const Request,
    response: *Response,
    /// Socket for this Connection.
    socket: SecureSocket,
    /// Slice of the URL Slug Captures
    captures: []const Capture,
    /// Map of the KV Query pairs in the URL
    queries: *const AnyCaseStringMap,
};
