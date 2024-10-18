const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/multithread");

fn hi_handler(ctx: *http.Context) void {
    const name = ctx.captures[0].string;
    const greeting = ctx.queries.get("greeting") orelse "Hi";

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
        \\ <h1>{s}, {s}!</h1>
        \\ <a href="/">click to go home!</a>
        \\ <p>Enter a name to say hi!</p>
        \\ <input type="text" id="textbox"/>
        \\ <input type="button" id="btn" value="Submit" onClick="redirectToHi()"/>
        \\ </body>
        \\ </html>
    , .{ greeting, name }) catch {
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

fn redir_handler(ctx: *http.Context) void {
    ctx.response.headers.add("Location", "/hi/redirect") catch unreachable;
    ctx.respond(.{
        .status = .@"Permanent Redirect",
        .mime = http.Mime.HTML,
        .body = "",
    });
}

fn post_handler(ctx: *http.Context) void {
    log.debug("Body: {s}", .{ctx.request.body});

    ctx.respond(.{
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

    var router = http.Router.init(allocator);
    defer router.deinit();

    try router.serve_embedded_file("/", http.Mime.HTML, @embedFile("index.html"));
    try router.serve_route("/hi/%s", http.Route.init().get(hi_handler));
    try router.serve_route("/redirect", http.Route.init().get(redir_handler));
    try router.serve_route("/post", http.Route.init().post(post_handler));

    var server = http.Server(.plain, .auto).init(.{
        .allocator = allocator,
        .threading = .auto,
    });
    defer server.deinit();

    try server.bind(host, port);
    try server.listen(.{ .router = &router });
}
