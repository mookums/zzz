const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/embed");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = http.Router.init(allocator);
    defer router.deinit();
    try router.serve_embedded_file("/", http.Mime.HTML, @embedFile("index.html"));

    var server = http.Server.init(.{ .allocator = allocator }, null);
    defer server.deinit();

    try server.bind(host, port);
    try server.listen(.{ .router = &router });
}
