const std = @import("std");
const zzz = @import("zzz");
const log = std.log.scoped(.@"examples/multithread");

fn hi_handler(_: zzz.Request, context: zzz.Context) zzz.Response {
    const name = zzz.Extractor(.String).extract_or(context, 2, "Unamed") catch "Unnamed";

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
    , .{name}) catch "";

    return zzz.Response.init(.OK, zzz.Mime.HTML, body);
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    // if multithreaded, you need a thread-safe allocator.
    const allocator = std.heap.page_allocator;

    var router = zzz.Router.init(allocator);
    try router.serve_embedded_file("/", zzz.Mime.HTML, @embedFile("index.html"));
    try router.serve_route("/hi/%s", zzz.Route.init().get(hi_handler));

    var server = zzz.Server.init(.{
        .allocator = allocator,
        .threading = .{ .multi_threaded = .auto },
        .size_read_buffer = 1024,
    }, router);
    defer server.deinit();
    try server.bind(host, port);
    try server.listen();
}
