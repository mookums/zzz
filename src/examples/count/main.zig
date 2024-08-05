const std = @import("std");
const zzz = @import("zzz");
const log = std.log.scoped(.@"examples/count");

fn count_handler(_: zzz.Request, context: zzz.Context) zzz.Response {
    const count = zzz.Extractor(.Unsigned).extract_or(context, 1, 0) catch 0;

    const body = std.fmt.allocPrint(context.allocator,
        \\ <!DOCTYPE html>
        \\ <html>
        \\ <body>
        \\ <h1>Hello, World!</h1>
        \\ <a href="/">click to go home!</a>
        \\ <p>Current Value: {d}</p>
        \\ <a href="/count/{d}">click here to increment!</a>
        \\ </body>
        \\ </html>
    , .{ count, count + 1 }) catch "";

    return zzz.Response.init(.OK, zzz.Mime.HTML, body);
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = zzz.Router.init(allocator);
    try router.serve_route("/", zzz.Route.init().get(struct {
        pub fn handler_fn(_: zzz.Request, _: zzz.Context) zzz.Response {
            const body =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <body>
                \\ <h1>Hello!</h1>
                \\ <a href="/count/0">click here to go to count!</a>
                \\ </body>
                \\ </html>
            ;

            return zzz.Response.init(.OK, zzz.Mime.HTML, body[0..]);
        }
    }.handler_fn));

    try router.serve_route("/count/%i", zzz.Route.init().get(count_handler));

    var server = zzz.Server.init(.{ .allocator = allocator }, router);
    defer server.deinit();

    try server.bind(host, port);
    try server.listen();
}
