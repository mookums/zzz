const std = @import("std");
const log = std.log.scoped(.@"examples/sse");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;
const Timer = tardy.Timer;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Respond = http.Respond;
const SSE = http.SSE;

fn sse_handler(ctx: *const Context, _: void) !Respond {
    var sse = try SSE.init(ctx);

    while (true) {
        sse.send(.{ .data = "hello from handler!" }) catch break;
        try Timer.delay(ctx.runtime, .{ .seconds = 1 });
    }

    return .responded;
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(allocator, .{ .threading = .single });
    defer t.deinit();

    const router = try Router.init(allocator, &.{
        Route.init("/").embed_file(.{ .mime = http.Mime.HTML }, @embedFile("./index.html")).layer(),
        Route.init("/stream").get({}, sse_handler).layer(),
    }, .{});

    // create socket for tardy
    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(256);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(.{
                    .stack_size = 1024 * 1024 * 4,
                    .socket_buffer_bytes = 1024 * 2,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
