const std = @import("std");
const builtin = @import("builtin");
const zzz = @import("lib.zig").zzz;

const stdout = std.io.getStdOut().writer();
const Response = @import("response.zig").Response;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var z3 = try zzz.init(host, port, .{ .allocator = std.heap.c_allocator });
    defer z3.deinit();
    try z3.bind();
    try z3.listen();
}
