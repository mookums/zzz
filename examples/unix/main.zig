const std = @import("std");
const log = std.log.scoped(.@"examples/benchmark");

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

pub const std_options: std.Options = .{ .log_level = .err };

pub fn root_handler(ctx: *const Context, _: void) !Respond {
    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = "This is an HTTP benchmark",
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(allocator, .{ .threading = .auto });
    defer t.deinit();

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, root_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    var socket = try Socket.init(.{ .unix = "/tmp/zzz.sock" });
    defer std.fs.deleteFileAbsolute("/tmp/zzz.sock") catch unreachable;
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(256);

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(.{});
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
