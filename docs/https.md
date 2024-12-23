# HTTPS
zzz utilizes [BearSSL](https://bearssl.org/) to provide a safe and performant TLS implementation. This TLS functionality is entirely separated from the I/O for maximum portability.

*Note: TLS Support is not **entirely** complete yet. It's a very rough area that will be getting cleaned up in a future development cycle*

## TLS Example
This is derived from the example at `examples/tls` and utilizes some certificates that are present within the repository.
```zig
const std = @import("std");
const log = std.log.scoped(.@"examples/tls");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Server = http.Server;
const Context = http.Context;
const Route = http.Route;
const Router = http.Router;

fn root_handler(ctx: *Context, _: void) !void {
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
    return try ctx.respond(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body[0..],
    });
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(
        .{ .thread_safe = true },
    ){ .backing_allocator = std.heap.c_allocator };
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .single,
    });
    defer t.deinit();

    var router = try Router.init(allocator, &.{
        Route.init("/embed/pico.min.css").serve_embedded_file(
            http.Mime.CSS,
            @embedFile("embed/pico.min.css"),
        ).layer(),

        Route.init("/").get({}, root_handler).layer(),

        Route.init("/kill").get({}, struct {
            pub fn handler_fn(ctx: *Context, _: void) !void {
                ctx.runtime.stop();
            }
        }.handler_fn).layer(),
    }, .{});
    defer router.deinit(allocator);
    router.print_route_tree();

    try t.entry(
        &router,
        struct {
            fn entry(rt: *Runtime, r: *const Router) !void {
                var server = Server.init(rt.allocator, .{
                    .security = .{ .tls = .{
                        .cert = .{ .file = .{ .path = "./examples/tls/certs/cert.pem" } },
                        .key = .{ .file = .{ .path = "./examples/tls/certs/key.pem" } },
                        .cert_name = "CERTIFICATE",
                        .key_name = "EC PRIVATE KEY",
                    } },
                });
                try server.bind(.{ .ip = .{ .host = host, .port = port } });
                try server.serve(r, rt);
            }
        }.entry,
        {},
        struct {
            fn exit(rt: *Runtime, _: void) !void {
                try Server.clean(rt);
            }
        }.exit,
    );
}
```
This example above passes the `.tls` variant of the enum to the HTTP Server and provides the location of the certificate and key to be used. It also has the functionality to pass in a buffer containing the cert and key data if that is preferable. You must also provide the certificate and key name as the PEM format allows for multiple items to be placed within the same file.

