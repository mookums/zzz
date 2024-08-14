const std = @import("std");
const Job = @import("../core/lib.zig").Job;
const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;
const Capture = @import("routing_trie.zig").Capture;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

// Every connection will be assigned a provision,
// this provision will follow it till the connection
// ends.
pub const Provision = struct {
    index: usize,
    job: Job,
    socket: std.posix.socket_t,
    buffer: []u8,
    captures: []Capture,
    request_buffer: std.ArrayList(u8),
    request: Request,
    response: Response,
    arena: std.heap.ArenaAllocator,
    pseudo: Pseudoslice,
    /// For tracking the read count or write count.
    count: usize,
    /// For tracking the end of the header on Requests.
    header_end: usize,
};
