const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/fs");

const Server = http.Server(.plain, .auto);
const Context = Server.Context;
const Route = Server.Route;
const Router = Server.Router;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(
        .{ .thread_safe = true },
    ){ .backing_allocator = std.heap.c_allocator };
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = Router.init(allocator);
    defer router.deinit();

    try router.serve_route("/", Route.init().get(struct {
        pub fn handler_fn(ctx: *Context) void {
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

    try router.serve_route("/kill", Route.init().get(struct {
        pub fn handler_fn(ctx: *Context) void {
            ctx.runtime.stop();

            ctx.respond(.{
                .status = .OK,
                .mime = http.Mime.HTML,
                .body = "",
            });
        }
    }.handler_fn));

    try router.serve_fs_dir("/static", "./examples/http/fs/static");

    var server = Server.init(.{
        .router = &router,
        .allocator = allocator,
        .threading = .auto,
        .size_connections_max = 256,
    });
    defer server.deinit();

    try server.bind(host, port);
    try server.listen();
}
