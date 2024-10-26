const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/tls");

const Server = http.Server(.{
    .tls = .{
        .cert = .{ .file = .{ .path = "./examples/http/tls/certs/cert.pem" } },
        .key = .{ .file = .{ .path = "./examples/http/tls/certs/key.pem" } },
        .cert_name = "CERTIFICATE",
        .key_name = "EC PRIVATE KEY",
    },
}, .auto);

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

    try router.serve_embedded_file("/embed/pico.min.css", http.Mime.CSS, @embedFile("embed/pico.min.css"));

    try router.serve_route("/", Route.init().get(struct {
        pub fn handler_fn(ctx: *Context) void {
            const body =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <head>
                \\ <link rel="stylesheet" href="/embed/pico.min.css"/>
                \\ </head>
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
            ctx.respond(.{
                .status = .Kill,
                .mime = http.Mime.HTML,
                .body = "",
            });
        }
    }.handler_fn));

    var server = Server.init(.{
        .router = &router,
        .allocator = allocator,
        .threading = .single,
    });
    defer server.deinit();

    try server.bind(host, port);
    try server.listen();
}
