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
    const max_conn = 512;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .single,
        .size_tasks_max = max_conn,
        .size_aio_jobs_max = max_conn,
        .size_aio_reap_max = max_conn,
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
            });
        }
    }.handler_fn));

    try t.entry(
        struct {
            fn entry(rt: *Runtime, alloc: std.mem.Allocator, r: *const Router) !void {
                var server = Server.init(.{
                    .allocator = alloc,
                    .size_connections_max = max_conn,
                });
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
