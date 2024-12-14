const std = @import("std");
const log = std.log.scoped(.@"examples/minram");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Server = http.Server(.plain, void);
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

    var router = try Router.init({}, &[_]Route{
        Route.init("/").get(struct {
            pub fn handler_fn(ctx: *Context) !void {
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
        }.handler_fn),
    });

    try t.entry(
        &router,
        struct {
            fn entry(rt: *Runtime, r: *const Router) !void {
                var server = Server.init(rt.allocator, .{
                    .backlog_count = 32,
                    .connection_count_max = max_conn,
                    .connection_arena_bytes_retain = 64,
                    .completion_reap_max = 8,
                    .socket_buffer_bytes = 512,
                    .header_count_max = 32,
                    .capture_count_max = 0,
                    .request_bytes_max = 2048,
                    .request_uri_bytes_max = 256,
                });
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
