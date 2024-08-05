const std = @import("std");
const zzz = @import("zzz");
const log = std.log.scoped(.@"examples/embed");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = zzz.Router.init(allocator);
    try router.serve_embedded_file("/", zzz.Mime.HTML, @embedFile("index.html"));

    var server = zzz.Server.init(.{ .allocator = allocator }, router);
    try server.bind(host, port);
    try server.listen();
}
