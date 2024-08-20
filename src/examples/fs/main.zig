const std = @import("std");
const zzz = @import("zzz");
const log = std.log.scoped(.@"examples/fs");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    const allocator = std.heap.page_allocator;

    var router = zzz.Router.init(allocator);
    try router.serve_route("/", zzz.Route.init().get(struct {
        pub fn handler_fn(_: zzz.Request, response: *zzz.Response, _: zzz.Context) void {
            const body =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <body>
                \\ <h1>Hello, World!</h1>
                \\ </body>
                \\ </html>
            ;

            response.set(.{
                .status = .OK,
                .mime = zzz.Mime.HTML,
                .body = body[0..],
            });
        }
    }.handler_fn));

    try router.serve_fs_dir("/static", "./src/examples/fs/static");

    var server = zzz.Server.init(.{
        .allocator = allocator,
        .threading = .{ .multi_threaded = .auto },
    }, router);
    try server.bind(host, port);
    try server.listen();
}
