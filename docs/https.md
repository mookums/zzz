# HTTPS
zzz utilizes [secsock](https://github.com/tardy-org/secsock) to provide a safe and performant TLS implementation. This TLS functionality is entirely separated from the I/O for maximum portability.

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
const Socket = tardy.Socket;

const Server = http.Server;
const Context = http.Context;
const Route = http.Route;
const Router = http.Router;
const Respond = http.Respond;

const secsock = zzz.secsock;
const SecureSocket = secsock.SecureSocket;

fn root_handler(ctx: *const Context, _: void) !Respond {
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

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body[0..],
    });
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(allocator, .{ .threading = .auto });
    defer t.deinit();

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, root_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    // create socket for tardy
    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1024);

    var bearssl = secsock.BearSSL.init(allocator);
    defer bearssl.deinit();
    try bearssl.add_cert_chain(
        "CERTIFICATE",
        @embedFile("certs/cert.pem"),
        "EC PRIVATE KEY",
        @embedFile("certs/key.pem"),
    );
    const secure = try bearssl.to_secure_socket(socket, .server);

    const EntryParams = struct {
        router: *const Router,
        socket: SecureSocket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = secure },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(.{ .stack_size = 1024 * 1024 * 8 });
                try server.serve(rt, p.router, .{ .secure = p.socket });
            }
        }.entry,
    );
}
```
This example above passes the `.tls` variant of the enum to the HTTP Server and provides the location of the certificate and key to be used. It also has the functionality to pass in a buffer containing the cert and key data if that is preferable. You must also provide the certificate and key name as the PEM format allows for multiple items to be placed within the same file.
