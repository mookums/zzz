const std = @import("std");
const log = std.log.scoped(.@"examples/basic");

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
const Middleware = http.Middleware;

const Next = http.Next;
const Response = http.Response;
const Respond = http.Respond;

const RateLimitConfig = http.Middlewares.RateLimitConfig;
const RateLimiting = http.Middlewares.RateLimiting;

fn base_handler(_: *const Context, _: void) !Respond {
    return Respond{ .standard = .{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = "Hello, world!",
    } };
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(allocator, .{ .threading = .single });
    defer t.deinit();

    var config = RateLimitConfig.init(allocator, 5, 30, null);
    defer config.deinit();

    var router = try Router.init(allocator, &.{
        RateLimiting(&config),
        Route.init("/").get({}, base_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    // create socket for tardy
    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(4096);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    const params: EntryParams = .{ .router = &router, .socket = socket };
    try t.entry(
        &params,
        struct {
            fn entry(rt: *Runtime, p: *const EntryParams) !void {
                var server = Server.init(rt.allocator, .{
                    .stack_size = 1024 * 1024 * 4,
                    .socket_buffer_bytes = 1024 * 2,
                    .keepalive_count_max = null,
                    .connection_count_max = 10,
                });
                try server.serve(rt, p.router, p.socket);
            }
        }.entry,
    );
}
