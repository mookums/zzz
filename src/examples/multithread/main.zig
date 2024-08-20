const std = @import("std");
const zzz = @import("zzz");
const log = std.log.scoped(.@"examples/multithread");

fn hi_handler(_: zzz.Request, response: *zzz.Response, context: zzz.Context) void {
    const name = context.captures[0].String;

    const body = std.fmt.allocPrint(context.allocator,
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
        response.set(.{
            .status = .@"Internal Server Error",
            .mime = zzz.Mime.HTML,
            .body = "Out of Memory!",
        });
        return;
    };

    response.set(.{
        .status = .OK,
        .mime = zzz.Mime.HTML,
        .body = body,
    });
}

fn redir_handler(_: zzz.Request, response: *zzz.Response, context: zzz.Context) void {
    _ = context;
    response.set(.{
        .status = .@"Permanent Redirect",
        .mime = zzz.Mime.HTML,
        .body = "",
    });

    response.headers.add("Location", "/hi/redirect") catch {
        response.set(.{
            .status = .@"Internal Server Error",
            .mime = zzz.Mime.HTML,
            .body = "Redirect Handler Failed",
        });
        return;
    };
}

fn post_handler(request: zzz.Request, response: *zzz.Response, _: zzz.Context) void {
    log.debug("Body: {s}", .{request.body});

    response.set(.{
        .status = .OK,
        .mime = zzz.Mime.HTML,
        .body = "",
    });
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    // if multithreaded, you need a thread-safe allocator.
    const allocator = std.heap.page_allocator;

    var router = zzz.Router.init(allocator);
    try router.serve_embedded_file("/", zzz.Mime.HTML, @embedFile("index.html"));
    try router.serve_route("/hi/%s", zzz.Route.init().get(hi_handler));
    try router.serve_route("/redirect", zzz.Route.init().get(redir_handler));
    try router.serve_route("/post", zzz.Route.init().post(post_handler));

    var server = zzz.Server.init(.{
        .allocator = allocator,
        .threading = .{ .multi_threaded = .auto },
    }, router);
    defer server.deinit();
    try server.bind(host, port);
    try server.listen();
}
