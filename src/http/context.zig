const std = @import("std");
const log = std.log.scoped(.@"zzz/http/context");

const Capture = @import("routing_trie.zig").Capture;
const QueryMap = @import("routing_trie.zig").QueryMap;

pub const Context = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    captures: []Capture,
    queries: *QueryMap,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, captures: []Capture, queries: *QueryMap) Context {
        return Context{
            .allocator = allocator,
            .path = path,
            .captures = captures,
            .queries = queries,
        };
    }
};
