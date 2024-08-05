const std = @import("std");
const zzz = @import("zzz");
const log = std.log.scoped(.@"examples/minram");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    // Upper Limit of 5 kB.
    var buffer = [_]u8{undefined} ** (1024 * 50);

    var fba = std.heap.FixedBufferAllocator.init(buffer[0..]);
    const allocator = fba.allocator();

    var router = zzz.Router.init(allocator);
    try router.serve_route("/", zzz.Route.init().get(struct {
        pub fn handler_fn(request: zzz.Request, context: zzz.Context) zzz.Response {
            _ = context;
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
        .backlog_kernel = 32,
        .entries_uring = 32,
        // If we are not using matching functionality,
        // we can set this to 0.
        .size_context_buffer = 0,
        .size_read_buffer = 512,
    }, router);

    try server.bind(host, port);
    try server.listen();
}
