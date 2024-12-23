const std = @import("std");
const log = std.log.scoped(.@"examples/middleware");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Next = http.Next;
const Middleware = http.Middleware;

fn root_handler(ctx: *Context, id: i8) !void {
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
    return try ctx.respond(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body[0..],
    });
}

fn pre_middleware(next: *Next, _: void) !void {
    log.info("pre request middleware: {s}", .{next.ctx.request.uri.?});
    return try next.run();
}

fn pre_fail_middleware(next: *Next, _: void) !void {
    log.info("pre fail request middleware: {s}", .{next.ctx.request.uri.?});
    return error.ExpectedFailure;
}

fn post_middleware(next: *Next, _: void) !void {
    log.info("post request middleware: {s}", .{next.ctx.request.uri.?});
    return try next.run();
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Creating our Tardy instance that
    // will spawn our runtimes.
    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .single,
    });
    defer t.deinit();

    const num: i8 = 12;

    var router = try Router.init(allocator, &.{
        Middleware.init().before({}, pre_middleware).after({}, post_middleware).layer(),
        Route.init("/").get(num, root_handler).layer(),
        Middleware.init().before({}, pre_fail_middleware).layer(),
        Route.init("/fail").get(num, root_handler).layer(),
    }, .{});
    defer router.deinit(allocator);
    router.print_route_tree();

    // This provides the entry function into the Tardy runtime. This will run
    // exactly once inside of each runtime (each thread gets a single runtime).
    try t.entry(
        &router,
        struct {
            fn entry(rt: *Runtime, r: *const Router) !void {
                var server = Server.init(rt.allocator, .{});
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
