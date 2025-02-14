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

const Compression = http.Middlewares.Compression;

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

    var gpa = std.heap.GeneralPurposeAllocator(
        .{ .thread_safe = true },
    ){ .backing_allocator = std.heap.c_allocator };
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(allocator, .{ .threading = .single });
    defer t.deinit();

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, root_handler).layer(),
        Compression(.{ .gzip = .{} }),
        Route.init("/embed/pico.min.css").embed_file(
            .{ .mime = http.Mime.CSS },
            @embedFile("embed/pico.min.css"),
        ).layer(),
    }, .{});
    defer router.deinit(allocator);

    // create socket for tardy
    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(1024);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(rt.allocator, .{
                    .security = .{ .tls = .{
                        .cert = .{ .file = .{ .path = "./examples/tls/certs/cert.pem" } },
                        .key = .{ .file = .{ .path = "./examples/tls/certs/key.pem" } },
                        .cert_name = "CERTIFICATE",
                        .key_name = "EC PRIVATE KEY",
                    } },
                    .stack_size = 1024 * 1024 * 8,
                });
                try server.serve(rt, p.router, p.socket);
            }
        }.entry,
    );
}
