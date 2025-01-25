const std = @import("std");

const ZeroCopy = @import("tardy").ZeroCopy;

const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Capture = @import("router/routing_trie.zig").Capture;
const QueryMap = @import("router/routing_trie.zig").QueryMap;

pub const Provision = struct {
    initalized: bool = false,
    recv_buffer: ZeroCopy(u8),
    buffer: []u8,
    arena: std.heap.ArenaAllocator,
    captures: []Capture,
    queries: QueryMap,
    request: Request,
    response: Response,
};
