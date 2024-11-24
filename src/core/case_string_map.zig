const std = @import("std");
const assert = std.debug.assert;

pub fn CaseStringMap(comptime T: type) type {
    return std.ArrayHashMap([]const u8, T, struct {
        pub fn hash(_: @This(), input: []const u8) u32 {
            var h: u32 = 0;
            for (input) |byte| {
                h = h *% 31 +% std.ascii.toLower(byte);
            }
            return h;
        }

        pub fn eql(_: @This(), first: []const u8, second: []const u8, _: usize) bool {
            if (first.len != second.len) return false;
            for (first, second) |a, b| {
                if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
            }
            return true;
        }
    }, true);
}

const testing = std.testing;

test "CaseStringMap: Add Stuff" {
    var csm = CaseStringMap([]const u8).init(testing.allocator);
    defer csm.deinit();

    try csm.putNoClobber("Content-Length", "100");
    try csm.putNoClobber("Host", "localhost:9999");

    const content_length = csm.get("content-length");
    try testing.expect(content_length != null);

    const host = csm.get("host");
    try testing.expect(host != null);
}
