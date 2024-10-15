const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/benchmark");

pub const std_options = .{
    .log_level = .err,
};

fn hi_handler(_: http.Request, response: *http.Response, context: http.Context) void {
    const name = context.captures[0].string;

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
            .mime = http.Mime.HTML,
            .body = "Out of Memory!",
        });
        return;
    };

    response.set(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body,
    });
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;
    const allocator = std.heap.page_allocator;

    var router = http.Router.init(allocator);
    defer router.deinit();
    try router.serve_embedded_file("/", http.Mime.HTML, @embedFile("index.html"));
    try router.serve_route("/hi/%s", http.Route.init().get(hi_handler));

    var server = http.Server(.plain, .auto).init(.{
        .allocator = allocator,
        .threading = .auto,
    });
    defer server.deinit();

    try server.bind(host, port);
    try server.listen(.{ .router = &router });
}
