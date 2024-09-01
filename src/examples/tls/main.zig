const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/tls");
pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    const allocator = std.heap.c_allocator;

    var router = http.Router.init(allocator);
    defer router.deinit();

    try router.serve_embedded_file("/embed/pico.min.css", http.Mime.CSS, @embedFile("embed/pico.min.css"));

    try router.serve_route("/", http.Route.init().get(struct {
        pub fn handler_fn(_: http.Request, response: *http.Response, _: http.Context) void {
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

            response.set(.{
                .status = .OK,
                .mime = http.Mime.HTML,
                .body = body[0..],
            });
        }
    }.handler_fn));

    try router.serve_route("/kill", http.Route.init().get(struct {
        pub fn handler_fn(_: http.Request, response: *http.Response, _: http.Context) void {
            response.set(.{
                .status = .Kill,
                .mime = http.Mime.HTML,
                .body = "",
            });
        }
    }.handler_fn));

    var server = http.Server.init(.{
        .allocator = allocator,
        .threading = .single_threaded,
        .encryption = .{
            .tls = .{
                .cert = "src/examples/tls/certs/cert.pem",
                .cert_name = "CERTIFICATE",
                .key = "src/examples/tls/certs/key.pem",
                .key_name = "EC PRIVATE KEY",
            },
        },
    }, null);
    defer server.deinit();

    try server.bind(host, port);
    try server.listen(.{ .router = &router });
}
