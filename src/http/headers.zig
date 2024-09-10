const std = @import("std");
const assert = std.debug.assert;
const HTTPError = @import("lib.zig").HTTPError;
const CaseStringMap = @import("case_string_map.zig").CaseStringMap;

pub const Headers = struct {
    allocator: std.mem.Allocator,
    map: CaseStringMap([]const u8),
    num_header_max: u32,

    pub fn init(allocator: std.mem.Allocator, num_header_max: u32) !Headers {
        var map = CaseStringMap([]const u8).init(allocator);
        try map.ensureTotalCapacity(num_header_max);

        return Headers{
            .allocator = allocator,
            .map = map,
            .num_header_max = num_header_max,
        };
    }

    pub fn deinit(self: *Headers) void {
        self.map.deinit();
    }

    pub fn add(self: *Headers, key: []const u8, value: []const u8) HTTPError!void {
        assert(std.mem.indexOfScalar(u8, key, ':') == null);
        if (self.map.count() == self.num_header_max) return HTTPError.TooManyHeaders;
        self.map.putAssumeCapacity(key, value);
    }

    pub fn get(self: Headers, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn clear(self: *Headers) void {
        self.map.clearRetainingCapacity();
    }
};

const testing = std.testing;

test "Adding and Getting Headers" {
    var headers = try Headers.init(testing.allocator, 3);
    defer headers.deinit();

    try headers.add("Content-Length", "100");
    try headers.add("Host", "localhost:9999");

    const content_length = headers.get("content-length");
    try testing.expect(content_length != null);

    const host = headers.get("host");
    try testing.expect(host != null);
}
