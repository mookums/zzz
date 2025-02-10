const std = @import("std");
const log = std.log.scoped(.@"zzz/http/method");

pub const Method = enum(u8) {
    GET = 0,
    HEAD = 1,
    POST = 2,
    PUT = 3,
    DELETE = 4,
    CONNECT = 5,
    OPTIONS = 6,
    TRACE = 7,
    PATCH = 8,

    fn encode(method: []const u8) u64 {
        var buffer = [1]u8{0} ** @sizeOf(u64);
        std.mem.copyForwards(u8, buffer[0..], method);

        return std.mem.readPackedIntNative(u64, buffer[0..], 0);
    }

    pub fn parse(method: []const u8) !Method {
        if (method.len > (comptime @sizeOf(u64)) or method.len == 0) {
            log.warn("unable to encode method: {s}", .{method});
            return error.CannotEncode;
        }

        const encoded = encode(method);

        return switch (encoded) {
            encode("GET") => Method.GET,
            encode("HEAD") => Method.HEAD,
            encode("POST") => Method.POST,
            encode("PUT") => Method.PUT,
            encode("DELETE") => Method.DELETE,
            encode("CONNECT") => Method.CONNECT,
            encode("OPTIONS") => Method.OPTIONS,
            encode("TRACE") => Method.TRACE,
            encode("PATCH") => Method.PATCH,
            else => {
                log.warn("unable to match method: {s} | {d}", .{ method, encoded });
                return error.CannotParse;
            },
        };
    }
};

const testing = std.testing;

test "Parsing Strings" {
    for (std.meta.tags(Method)) |method| {
        const method_string = @tagName(method);
        try testing.expectEqual(method, Method.parse(method_string));
    }
}
