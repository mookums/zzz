const std = @import("std");
const log = std.log.scoped(.@"examples/minram");

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
        .{ .enable_memory_limit = true },
    ){ .requested_memory_limit = 1024 * 300 };
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const max_conn = 16;

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

    try router.serve_route("/", Route.init().get({}, struct {
        pub fn handler_fn(ctx: *Context, _: void) !void {
            const body =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <body>
                \\ <h1>Hello, World!</h1>
                \\ </body>
                \\ </html>
            ;

            try ctx.respond(.{
                .status = .OK,
                .mime = http.Mime.HTML,
                .body = body[0..],
            });
        }
    }.handler_fn));

    try t.entry(
        &router,
        struct {
            fn entry(rt: *Runtime, r: *const Router) !void {
                var server = Server.init(.{
                    .allocator = rt.allocator,
                    .size_backlog = 32,
                    .size_connections_max = max_conn,
                    .size_connection_arena_retain = 64,
                    .size_completions_reap_max = 8,
                    .size_socket_buffer = 512,
                    .num_header_max = 32,
                    .num_captures_max = 0,
                    .size_request_max = 2048,
                    .size_request_uri_max = 256,
                });
                try server.bind(host, port);
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
