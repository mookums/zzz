const std = @import("std");
const zzz = @import("zzz");
const log = std.log.scoped(.@"examples/basic");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();

    var router = zzz.Router.init(allocator);
    try router.serve_fs_dir("/static", "./src/examples/fs/static");

    var server = zzz.Server.init(.{ .allocator = allocator }, router);
    try server.bind(host, port);
    try server.listen();
}
