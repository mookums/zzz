const std = @import("std");
const log = std.log.scoped(.@"zzz/context");

const Capture = @import("routing_trie.zig").Capture;

pub const Context = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    captures: []Capture,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, captures: []Capture) Context {
        return Context{
            .allocator = allocator,
            .path = path,
            .captures = captures,
        };
    }
};
