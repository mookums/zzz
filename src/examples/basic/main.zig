const std = @import("std");
const zzz = @import("zzz");
const log = std.log.scoped(.@"examples/basic");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = zzz.Router.init(allocator);
    try router.serve_route(zzz.Route.init("/").get(struct {
        pub fn handler_fn(request: zzz.Request) zzz.Response {
            const body =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <body>
                \\ <h1>Hello, World!</h1>
                \\ </body>
                \\ </html>
            ;

            _ = request;
            return zzz.Response.init(.OK, zzz.Mime.HTML, body[0..]);
        }
    }.handler_fn));

    var server = zzz.Server.init(.{ .allocator = allocator }, router);
    try server.bind(host, port);
    try server.listen();
}
