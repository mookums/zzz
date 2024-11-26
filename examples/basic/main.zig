const std = @import("std");
const log = std.log.scoped(.@"examples/basic");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = @import("tardy");
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Server = http.Server(.plain);
const Router = Server.Router;
const Context = Server.Context;
const Route = Server.Route;

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

    var router = Router.init(allocator);
    defer router.deinit();

    const num: i8 = 12;

    try router.serve_route("/", Route.init().get(&num, struct {
        fn handler_fn(ctx: *Context, id: *const i8) !void {
            const body_fmt =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <body>
                \\ <h1>Hello, World!</h1>
                \\ <p>id: {d}</p>
                \\ </body>
                \\ </html>
            ;

            const body = try std.fmt.allocPrint(ctx.allocator, body_fmt, .{id.*});

            // This is the standard response and what you
            // will usually be using. This will send to the
            // client and then continue to await more requests.
            try ctx.respond(.{
                .status = .OK,
                .mime = http.Mime.HTML,
                .body = body[0..],
            });
        }
    }.handler_fn));

    try router.serve_route("/echo", Route.init().post({}, struct {
        fn handler_fn(ctx: *Context, _: void) !void {
            const body = try ctx.allocator.dupe(u8, ctx.request.body);
            try ctx.respond(.{
                .status = .OK,
                .mime = http.Mime.HTML,
                .body = body[0..],
            });
        }
    }.handler_fn));

    router.serve_not_found(Route.init().get({}, struct {
        fn handler_fn(ctx: *Context, _: void) !void {
            try ctx.respond(.{
                .status = .@"Not Found",
                .mime = http.Mime.HTML,
                .body = "Not Found Handler!",
            });
        }
    }.handler_fn));

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
