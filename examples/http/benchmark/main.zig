const std = @import("std");
const log = std.log.scoped(.@"examples/benchmark");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = @import("tardy");
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Server = http.Server(.plain);
const Context = Server.Context;
const Route = Server.Route;
const Router = Server.Router;

pub const std_options = .{
    .log_level = .err,
};

fn hi_handler(ctx: *Context) void {
    const name = ctx.captures[0].string;

    const body = std.fmt.allocPrint(ctx.allocator,
        \\ <!DOCTYPE html>
        \\ <html>
        \\ <body>
        \\ <script>
        \\ function redirectToHi() {{
        \\      var textboxValue = document.getElementById('textbox').value;
        \\      window.location.href = '/hi/' + encodeURIComponent(textboxValue);
        \\ }}
        \\ </script>
        \\ <h1>Hi, {s}!</h1>
        \\ <a href="/">click to go home!</a>
        \\ <p>Enter a name to say hi!</p>
        \\ <input type="text" id="textbox"/>
        \\ <input type="button" id="btn" value="Submit" onClick="redirectToHi()"/>
        \\ </body>
        \\ </html>
    , .{name}) catch {
        ctx.respond(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.HTML,
            .body = "Out of Memory!",
        });
        return;
    };

    ctx.respond(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body,
    });
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;
    const max_conn = 1024;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .auto,
        .size_tasks_max = max_conn,
        .size_aio_jobs_max = max_conn,
        .size_aio_reap_max = max_conn,
    });
    defer t.deinit();

    var router = Router.init(allocator);
    defer router.deinit();
    try router.serve_embedded_file("/", http.Mime.HTML, @embedFile("index.html"));
    try router.serve_route("/hi/%s", Route.init().get(hi_handler));

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
