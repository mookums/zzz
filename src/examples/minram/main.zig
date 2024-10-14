const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/minram");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){ .requested_memory_limit = 1024 * 300 };
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = http.Router.init(allocator);
    defer router.deinit();

    try router.serve_route("/", http.Route.init().get(struct {
        pub fn handler_fn(_: http.Request, response: *http.Response, _: http.Context) void {
            const body =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <body>
                \\ <h1>Hello, World!</h1>
                \\ </body>
                \\ </html>
            ;

            response.set(.{
                .status = .OK,
                .mime = http.Mime.HTML,
                .body = body[0..],
            });
        }
    }.handler_fn));

    var server = http.Server(.plain, .auto).init(.{
        .allocator = allocator,
        .threading = .single,
        .size_backlog = 32,
        .size_connections_max = 16,
        .size_connection_arena_retain = 64,
        .size_socket_buffer = 512,
    });

    try server.bind(host, port);
    try server.listen(.{
        .router = &router,
        .num_header_max = 32,
        .num_captures_max = 0,
        .size_request_max = 2048,
        .size_request_uri_max = 256,
    });
}
