const std = @import("std");
const log = std.log.scoped(.@"examples/http_blocking");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    _ = host;
    _ = port;
    _ = allocator;
}
