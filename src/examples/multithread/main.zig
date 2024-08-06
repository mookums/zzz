const std = @import("std");
const zzz = @import("zzz");
const log = std.log.scoped(.@"examples/basic");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    const allocator = std.heap.page_allocator;

    var router = zzz.Router.init(allocator);
    try router.serve_embedded_file("/", zzz.Mime.HTML, @embedFile("index.html"));

    var server = zzz.Server.init(.{
        // if multithreaded, you need a thread-safe allocator.
        .allocator = allocator,
        .threading = .{ .multi_threaded = 4 },
    }, router);
    defer server.deinit();
    try server.bind(host, port);
    try server.listen();
}
