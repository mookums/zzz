const std = @import("std");
const log = std.log.scoped(.@"zzz/http/context");

const Capture = @import("routing_trie.zig").Capture;
const QueryMap = @import("routing_trie.zig").QueryMap;
const Injector = @import("./injector.zig").Injector;

pub const Context = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    captures: []Capture,
    queries: *QueryMap,
    injector: Injector,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, captures: []Capture, queries: *QueryMap, injector: Injector) Context {
        return Context{
            .allocator = allocator,
            .path = path,
            .captures = captures,
            .queries = queries,
            .injector = injector,
        };
    }
};
