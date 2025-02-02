const std = @import("std");
const log = std.log.scoped(.@"examples/middleware");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Next = http.Next;
const Respond = http.Respond;
const Middleware = http.Middleware;

fn root_handler(ctx: *const Context, id: i8) !Respond {
    const body_fmt =
        \\ <!DOCTYPE html>
        \\ <html>
        \\ <body>
        \\ <h1>Hello, World!</h1>
        \\ <p>id: {d}</p>
        \\ </body>
        \\ </html>
    ;
    const body = try std.fmt.allocPrint(ctx.allocator, body_fmt, .{id});

    // This is the standard response and what you
    // will usually be using. This will send to the
    // client and then continue to await more requests.
    return Respond{ .standard = .{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body[0..],
    } };
}

fn passing_middleware(next: *Next, _: void) !Respond {
    log.info("pass middleware: {s}", .{next.context.request.uri.?});
    return try next.run();
}

fn failing_middleware(next: *Next, _: void) !Respond {
    log.info("fail middleware: {s}", .{next.context.request.uri.?});
    return Respond{ .standard = .{
        .status = .@"Internal Server Error",
        .mime = http.Mime.HTML,
        .body = "",
    } };
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(allocator, .{ .threading = .single });
    defer t.deinit();

    const num: i8 = 12;

    var router = try Router.init(allocator, &.{
        Middleware.init({}, passing_middleware).layer(),
        Route.init("/").get(num, root_handler).layer(),
        Middleware.init({}, failing_middleware).layer(),
        Route.init("/fail").get(num, root_handler).layer(),
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
                var server = Server.init(rt.allocator, .{});
                try server.serve(rt, p.router, p.socket);
            }
        }.entry,
    );
}
