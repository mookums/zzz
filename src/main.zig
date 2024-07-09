const std = @import("std");
const builtin = @import("builtin");
const stdout = std.io.getStdOut().writer();
const zzz = @import("lib.zig").zzz;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var z3 = zzz(.{}).init(.{
        .allocator = allocator,
    });

    try z3.bind(host, port);
    try z3.listen();
}
