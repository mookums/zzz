const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/valgrind");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = http.Router.init(allocator);
    defer router.deinit();

    try router.serve_route("/", http.Route.init().get(struct {
        pub fn handler_fn(ctx: *http.Context) void {
            const body =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <body>
                \\ <h1>Hello, World!</h1>
                \\ </body>
                \\ </html>
            ;

            ctx.respond(.{
                .status = .OK,
                .mime = http.Mime.HTML,
                .body = body[0..],
            });
        }
    }.handler_fn));

    try router.serve_route("/kill", http.Route.init().get(struct {
        pub fn handler_fn(ctx: *http.Context) void {
            ctx.respond(.{
                .status = .Kill,
                .mime = http.Mime.HTML,
                .body = "",
            });
        }
    }.handler_fn));

    var server = http.Server(.plain, .auto).init(.{
        .allocator = allocator,
        .threading = .single,
    });
    defer server.deinit();

    try server.bind(host, port);
    try server.listen(.{ .router = &router });
}
