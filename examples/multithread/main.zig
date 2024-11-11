const std = @import("std");
const log = std.log.scoped(.@"examples/multithread");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = @import("tardy");
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Server = http.Server(.plain);
const Router = Server.Router;
const Context = Server.Context;
const Route = Server.Route;

fn hi_handler(ctx: *Context, _: void) !void {
    const name = ctx.captures[0].string;
    const greeting = ctx.queries.get("greeting") orelse "Hi";

    const body = try std.fmt.allocPrint(ctx.allocator,
        \\ <!DOCTYPE html>
        \\ <html>
        \\ <body>
        \\ <script>
        \\ function redirectToHi() {{
        \\      var textboxValue = document.getElementById('textbox').value;
        \\      window.location.href = '/hi/' + encodeURIComponent(textboxValue);
        \\ }}
        \\ </script>
        \\ <h1>{s}, {s}!</h1>
        \\ <a href="/">click to go home!</a>
        \\ <p>Enter a name to say hi!</p>
        \\ <input type="text" id="textbox"/>
        \\ <input type="button" id="btn" value="Submit" onClick="redirectToHi()"/>
        \\ </body>
        \\ </html>
    , .{ greeting, name });

    try ctx.respond(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body,
    });
}

fn redir_handler(ctx: *Context, _: void) !void {
    try ctx.response.headers.add("Location", "/hi/redirect");

    try ctx.respond(.{
        .status = .@"Permanent Redirect",
        .mime = http.Mime.HTML,
        .body = "",
    });
}

fn post_handler(ctx: *Context, _: void) !void {
    log.debug("Body: {s}", .{ctx.request.body});

    try ctx.respond(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = "",
    });
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    // if multithreaded, you need a thread-safe allocator.
    var gpa = std.heap.GeneralPurposeAllocator(
        .{ .thread_safe = true },
    ){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .auto,
    });
    defer t.deinit();

    var router = Router.init(allocator);
    defer router.deinit();

    try router.serve_embedded_file("/", http.Mime.HTML, @embedFile("index.html"));
    try router.serve_route("/hi/%s", Route.init().get({}, hi_handler));
    try router.serve_route("/redirect", Route.init().get({}, redir_handler));
    try router.serve_route("/post", Route.init().post({}, post_handler));

    try t.entry(
        &router,
        struct {
            fn entry(rt: *Runtime, r: *const Router) !void {
                var server = Server.init(.{ .allocator = rt.allocator });
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
