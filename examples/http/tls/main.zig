const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/tls");

pub const Post = struct {
    id: u32,
    title: []const u8,
    body: []const u8,
};

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    const allocator = std.heap.c_allocator;

    var user = Post{ .body = "testing injection", .title = "TEST", .id = 34 };
    const cx = .{&user};

    var router = http.Router.init(allocator, cx);
    defer router.deinit();

    try router.serve_embedded_file("/embed/pico.min.css", http.Mime.CSS, @embedFile("embed/pico.min.css"));

    try router.serve_route("/", http.Route.init().get(struct {
        pub fn handler_fn(_: http.Request, response: *http.Response, ctx: http.Context) void {
            // const body =
            //     \\ <!DOCTYPE html>
            //     \\ <html>
            //     \\ <head>
            //     \\ <link rel="stylesheet" href="/embed/pico.min.css"/>
            //     \\ </head>
            //     \\ <body>
            //     \\ <h1>Hello, World!</h1>
            //     \\ </body>
            //     \\ </html>
            // ;
            const post = try ctx.injector.get(*Post);
            var out = try std.ArrayList(u8).init(ctx.allocator);
            defer out.deinit();
            try std.json.stringify(post, .{}, out.writer());
            response.set(.{
                .status = .OK,
                .mime = http.Mime.HTML,
                .body = out[0..],
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

    var server = http.Server(
        .{
            .tls = .{
                .cert = .{
                    .file = .{ .path = "./examples/http/tls/certs/cert.pem" },
                },
                .key = .{
                    .file = .{ .path = "./examples/http/tls/certs/key.pem" },
                },
                .cert_name = "CERTIFICATE",
                .key_name = "EC PRIVATE KEY",
            },
        },
        .auto,
    ).init(.{
        .allocator = allocator,
        .threading = .single,
    });
    defer server.deinit();

    try server.bind(host, port);
    try server.listen(.{ .router = &router });
}
