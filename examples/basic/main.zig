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

const CompressMiddleware = http.CompressMiddleware;
const RateLimitMiddleware = http.RateLimitMiddleware;
const ThreadSafeRateLimit = http.ThreadSafeRateLimit;

fn base_handler(_: Context, _: void) !Respond {
    return .{
        .status = .OK,
        .mime = http.Mime.TEXT,
        .body = "Hello, world!",
    };
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Creating our Tardy instance that
    // will spawn our runtimes.
    var t = try Tardy.init(allocator, .{
        .threading = .auto,
        .size_tasks_initial = 128,
        .size_aio_reap_max = 128,
    });
    defer t.deinit();

    var limiter = ThreadSafeRateLimit.init(allocator);
    defer limiter.deinit();

    var router = try Router.init(allocator, &.{
        //RateLimitMiddleware(std.time.ms_per_s, &limiter),
        //CompressMiddleware(.{ .gzip = .{} }),
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
        socket: *Socket,
    };

    const params: EntryParams = .{ .router = &router, .socket = &socket };

    // This provides the entry function into the Tardy runtime. This will run
    // exactly once inside of each runtime (each thread gets a single runtime).
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
