# Getting Started
zzz is a networking framework that allows for modularity and flexibility in design. For most use cases, this flexibility is not a requirement and so various defaults are provided.

For this guide, we will assume that you are running on a modern Linux platform and looking to design a service that utilizes HTTP.

`zig fetch --save https://github.com/mookums/zzz/archive/main.tar.gz`

## Hello, World!
We can write a quick example that serves out "Hello, World" responses to any client that connects to the server. This example is the same as the one that is provided within the `src/examples/basic` directory.

```zig
const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/basic");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    const allocator = std.heap.page_allocator;

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
    });
    defer server.deinit();

    try server.bind(host, port);
    try server.listen(.{
        .router = &router,
    });
}
```

The snippet above handles all of the basic tasks involved with serving a plaintext route using zzz's HTTP implementation. 
