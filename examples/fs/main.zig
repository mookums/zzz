const std = @import("std");
const log = std.log.scoped(.@"examples/fs");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;
const Dir = tardy.Dir;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;
const FsDir = http.FsDir;

const Compression = http.Middlewares.Compression;

fn base_handler(_: *const Context, dir: Dir) !Respond {
    log.debug("dir={}", .{dir});
    const body =
        \\ <!DOCTYPE html>
        \\ <html>
        \\ <body>
        \\ <h1>Hello, World!</h1>
        \\ </body>
        \\ </html>
    ;

    return Respond{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body[0..],
    };
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(
        .{ .thread_safe = true },
    ){ .backing_allocator = std.heap.c_allocator };
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(allocator, .{ .threading = .auto });
    defer t.deinit();

    const static_dir = Dir.from_std(try std.fs.cwd().openDir("examples/fs/static", .{}));

    var router = try Router.init(allocator, &.{
        Route.init("/").get(static_dir, base_handler).layer(),
        Compression(.{ .gzip = .{} }),
        FsDir.serve("/", static_dir),
    }, .{});
    defer router.deinit(allocator);
    router.print_route_tree();

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(256);

    const params: EntryParams = .{ .router = &router, .socket = socket };
    try t.entry(
        &params,
        struct {
            fn entry(rt: *Runtime, p: *const EntryParams) !void {
                var server = Server.init(rt.allocator, .{
                    .stack_size = 1024 * 1024 * 4,
                    .socket_buffer_bytes = 1024 * 4,
                });
                try server.serve(rt, p.router, p.socket);
            }
        }.entry,
    );
}
