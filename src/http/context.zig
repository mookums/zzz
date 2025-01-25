const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/context");

const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;

const Capture = @import("router/routing_trie.zig").Capture;
const QueryMap = @import("router/routing_trie.zig").QueryMap;
const Route = @import("router/route.zig").Route;
const Provision = @import("provision.zig").Provision;

const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const ResponseSetOptions = Response.ResponseSetOptions;
const Mime = @import("mime.zig").Mime;
const SSE = @import("sse.zig").SSE;
const MiddlewareWithData = @import("router/middleware.zig").MiddlewareWithData;
const Next = @import("router/middleware.zig").Next;

const Runtime = @import("tardy").Runtime;
const Server = @import("server.zig").Server;

// Context is dependent on the server that gets created.
pub const Context = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    runtime: *Runtime,
    /// The Request that triggered this handler.
    request: *const Request,
    /// Address for this Request/Response.
    address: std.net.Address,
};
