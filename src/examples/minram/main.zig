const std = @import("std");
const zzz = @import("zzz");
const log = std.log.scoped(.@"examples/minram");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var buffer = [_]u8{undefined} ** (1024 * 60);
    var fba = std.heap.FixedBufferAllocator.init(buffer[0..]);
    const allocator = fba.allocator();

    var router = zzz.Router.init(allocator);
    try router.serve_route("/", zzz.Route.init().get(struct {
        pub fn handler_fn(request: zzz.Request, _: zzz.Context) zzz.Response {
            const body =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <body>
                \\ <h1>Hello, World!</h1>
                \\ </body>
                \\ </html>
            ;

            _ = request;
            return zzz.Response.init(.OK, zzz.Mime.HTML, body[0..]);
        }
    }.handler_fn));

    var server = zzz.Server.init(.{
        .allocator = allocator,
        .size_backlog_kernel = 32,
        .size_connections_max = 16,
        .size_context_arena_retain = 64,
        .size_request_max = 2048,
        .size_socket_buffer = 512,
    }, router);

    try server.bind(host, port);
    try server.listen();
}
