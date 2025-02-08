const std = @import("std");
const assert = std.debug.assert;

const Pool = @import("tardy").Pool;

const AnyCaseStringContext = struct {
    const Self = @This();

    pub fn hash(_: Self, key: []const u8) u64 {
        var wyhash = std.hash.Wyhash.init(0);
        for (key) |b| wyhash.update(&.{std.ascii.toLower(b)});
        return wyhash.final();
    }

    pub fn eql(_: Self, key1: []const u8, key2: []const u8) bool {
        if (key1.len != key2.len) return false;
        for (key1, key2) |b1, b2| if (std.ascii.toLower(b1) != std.ascii.toLower(b2)) return false;
        return true;
    }
};

pub const AnyCaseStringMap = std.HashMap([]const u8, []const u8, AnyCaseStringContext, 80);

const testing = std.testing;

test "AnyCaseStringMap: Add Stuff" {
    var map = AnyCaseStringMap.init(testing.allocator);
    defer map.deinit();

    try map.put("Content-Length", "100");
    try map.put("Host", "localhost:9999");

    const content_length = map.get("Content-length");
    try testing.expect(content_length != null);

    const host = map.get("host");
    try testing.expect(host != null);
}
