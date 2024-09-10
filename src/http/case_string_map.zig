const std = @import("std");

pub fn CaseStringMap(comptime T: type) type {
    return std.HashMap([]const u8, T, struct {
        pub fn hash(self: @This(), input: []const u8) u64 {
            _ = self;
            var wyhash = std.hash.Wyhash.init(0);

            for (input) |byte| {
                const lower = std.ascii.toLower(byte);
                wyhash.update((&lower)[0..1]);
            }

            return wyhash.final();
        }

        pub fn eql(self: @This(), first: []const u8, second: []const u8) bool {
            _ = self;

            if (first.len != second.len) {
                return false;
            }

            var equal = true;
            for (first, second) |fbyte, sbyte| {
                equal = equal and (std.ascii.toLower(fbyte) ^ std.ascii.toLower(sbyte)) == 0;
            }

            return equal;
        }
    }, 80);
}

const testing = std.testing;

test "Adding and Retrieving (CaseStringMap)" {
    var map = CaseStringMap([]const u8).init(testing.allocator);
    defer map.deinit();

    try map.putNoClobber("Content-Length", "100");
    try map.putNoClobber("Host", "localhost:9999");

    const content_length = try map.getOrPut("content-length");
    try testing.expect(content_length.found_existing);

    const host = try map.getOrPut("host");
    try testing.expect(host.found_existing);
}
