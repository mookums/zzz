const std = @import("std");
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Runtime = @import("tardy").Runtime;

const secsock = @import("secsock");
const SecureSocket = secsock.SecureSocket;

const Capture = @import("router/routing_trie.zig").Capture;

const TypedStorage = @import("../core/typed_storage.zig").TypedStorage;
const AnyCaseStringMap = @import("../core/any_case_string_map.zig").AnyCaseStringMap;

/// HTTP Context. Contains all of the various information
/// that will persist throughout the lifetime of this Request/Response.
pub const Context = struct {
    allocator: std.mem.Allocator,
    /// Not safe to access unless you are manually sending the headers
    /// and returning the .responded variant of Respond.
    header_buffer: *std.ArrayList(u8),
    runtime: *Runtime,
    /// The Request that triggered this handler.
    request: *const Request,
    response: *Response,
    /// Storage
    storage: *TypedStorage,
    /// Socket for this Connection.
    socket: SecureSocket,
    /// Slice of the URL Slug Captures
    captures: []const Capture,
    /// Map of the KV Query pairs in the URL
    queries: *const AnyCaseStringMap,
};
