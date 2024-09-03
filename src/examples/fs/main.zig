const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/fs");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    const allocator = std.heap.page_allocator;

    var router = http.Router.init(allocator);
    defer router.deinit();

    try router.serve_route("/", http.Route.init().get(struct {
        pub fn handler_fn(_: http.Request, response: *http.Response, _: http.Context) void {
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
                .mime = http.Mime.HTML,
                .body = body[0..],
            });
        }
    }.handler_fn));

    try router.serve_fs_dir("/static", "./src/examples/fs/static");

    var server = http.Server(.plain).init(.{ .allocator = allocator }, null);
    try server.bind(host, port);
    try server.listen(.{ .router = &router });
}
