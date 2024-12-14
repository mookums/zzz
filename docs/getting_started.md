# Getting Started
zzz is a networking framework that allows for modularity and flexibility in design. For most use cases, this flexibility is not a requirement and so various defaults are provided.

For this guide, we will assume that you are running on a modern Linux platform and looking to design a service that utilizes HTTP. We will need both `zzz` and `tardy` for this to work.
You will need to match the version of Tardy that zzz is currently using to the version of Tardy you currently use within your program. This will eventually be standardized.

These are the current latest releases and are compatible.

`zig fetch --save git+https://github.com/mookums/zzz#v0.2.0`

`zig fetch --save git+https://github.com/mookums/tardy#v0.1.0`

## Hello, World!
We can write a quick example that serves out "Hello, World" responses to any client that connects to the server. This example is the same as the one that is provided within the `examples/basic` directory.

```zig
const std = @import("std");
const log = std.log.scoped(.@"examples/basic");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Server = http.Server(.plain, *const i8);
const Router = Server.Router;
const Context = Server.Context;
const Route = Server.Route;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Creating our Tardy instance that
    // will spawn our runtimes.
    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .single,
    });
    defer t.deinit();

    const num: i8 = 12;

    var router = try Router.init(&num, &[_]Route{
        Route.init("/").get(struct {
            fn handler_fn(ctx: *Context) !void {
                const body_fmt =
                    \\ <!DOCTYPE html>
                    \\ <html>
                    \\ <body>
                    \\ <h1>Hello, World!</h1>
                    \\ <p>id: {d}</p>
                    \\ </body>
                    \\ </html>
                ;

                const body = try std.fmt.allocPrint(ctx.allocator, body_fmt, .{ctx.state.*});

                // This is the standard response and what you
                // will usually be using. This will send to the
                // client and then continue to await more requests.
                try ctx.respond(.{
                    .status = .OK,
                    .mime = http.Mime.HTML,
                    .body = body[0..],
                });
            }
        }.handler_fn),

        Route.init("/echo").post(struct {
            fn handler_fn(ctx: *Context) !void {
                const body = if (ctx.request.body) |b|
                    try ctx.allocator.dupe(u8, b)
                else
                    "";

                try ctx.respond(.{
                    .status = .OK,
                    .mime = http.Mime.HTML,
                    .body = body[0..],
                });
            }
        }.handler_fn),
    });

    router.serve_not_found(Route.init("/notfound").get(struct {
        fn handler_fn(ctx: *Context) !void {
            try ctx.respond(.{
                .status = .@"Not Found",
                .mime = http.Mime.HTML,
                .body = "Not Found Handler!",
            });
        }
    }.handler_fn));

    // This provides the entry function into the Tardy runtime. This will run
    // exactly once inside of each runtime (each thread gets a single runtime).
    try t.entry(
        &router,
        struct {
            fn entry(rt: *Runtime, r: *const Router) !void {
                var server = Server.init(rt.allocator, .{});
                try server.bind(.{ .ip = .{ .host = host, .port = port } });
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
```

The snippet above handles all of the basic tasks involved with serving a plaintext route using zzz's HTTP implementation. 
