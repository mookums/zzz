const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/minram");

const Server = http.Server(.plain, .auto);
const Context = Server.Context;
const Route = Server.Route;
const Router = Server.Router;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(
        .{ .enable_memory_limit = true },
    ){ .requested_memory_limit = 1024 * 300 };
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

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

    var server = Server.init(.{
        .router = &router,
        .allocator = allocator,
        .threading = .single,
        .size_backlog = 32,
        .size_connections_max = 16,
        .size_connection_arena_retain = 64,
        .size_completions_reap_max = 8,
        .size_socket_buffer = 512,
        .num_header_max = 32,
        .num_captures_max = 0,
        .size_request_max = 2048,
        .size_request_uri_max = 256,
    });
    defer server.deinit();

    try server.bind(host, port);
    try server.listen();
}
