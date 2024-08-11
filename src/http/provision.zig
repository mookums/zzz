const std = @import("std");
const Job = @import("../core/lib.zig").Job;
const Capture = @import("routing_trie.zig").Capture;

// Every connection will be assigned a provision,
// this provision will follow it till the connection
// ends.
pub const Provision = struct {
    index: usize,
    job: Job,
    socket: std.posix.socket_t,
    buffer: []u8,
    captures: []Capture,
    request: std.ArrayList(u8),
    arena: std.heap.ArenaAllocator,
};
