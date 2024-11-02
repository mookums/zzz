const std = @import("std");
const log = std.log.scoped(.@"examples/fs");

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

    var gpa = std.heap.GeneralPurposeAllocator(
        .{ .thread_safe = true },
    ){ .backing_allocator = std.heap.c_allocator };
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .auto,
    });
    defer t.deinit();

    var router = Router.init(allocator);
    defer router.deinit();

    try router.serve_route("/", Route.init().get(struct {
        pub fn handler_fn(ctx: *Context) void {
            const body =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <body>
                \\ <h1>Hello, World!</h1>
                \\ </body>
                \\ </html>
            ;

            ctx.respond(.{
                .status = .OK,
                .mime = http.Mime.HTML,
                .body = body[0..],
            }) catch unreachable;
        }
    }.handler_fn));

    try router.serve_route("/kill", Route.init().get(struct {
        pub fn handler_fn(ctx: *Context) void {
            ctx.runtime.stop();
        }
    }.handler_fn));

    try router.serve_fs_dir("/static", "./examples/http/fs/static");

    try t.entry(
        struct {
            fn entry(rt: *Runtime, alloc: std.mem.Allocator, r: *const Router) !void {
                var server = Server.init(.{ .allocator = alloc });
                try server.bind(host, port);
                try server.serve(r, rt);
            }
        }.entry,
        &router,
        struct {
            fn exit(rt: *Runtime, _: std.mem.Allocator, _: void) void {
                Server.clean(rt) catch unreachable;
            }
        }.exit,
        {},
    );
}
