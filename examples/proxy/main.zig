const std = @import("std");
const log = std.log.scoped(.@"examples/proxy");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = @import("tardy");
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Client = http.Client;

const Server = http.Server(.plain);
const Router = Server.Router;
const Context = Server.Context;
const Route = Server.Route;

// this uses the new zzz HTTP client implementation as a proxy, firing off the requests
// and returning the retrieved data.
fn fetch_task(_: *Runtime, response: ?*const http.Response, ctx: *Context) !void {
    if (response) |resp| {
        try ctx.respond(.{
            .status = .OK,
            .mime = resp.mime.?,
            // You need to dupe it out since the client
            // response data is cleaned up after this callback runs.
            .body = try ctx.allocator.dupe(u8, resp.body.?),
        });
    } else {
        // If our fetch errors while running, we will get a null here.
        try ctx.respond(.{
            .status = .@"Internal Server Error",
            .mime = http.Mime.HTML,
            .body = "NOT FOUND!",
        });
    }
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9863;
    //const proxy_path = "http://httpforever.com";
    //const proxy_path = "http://http.badssl.com";
    const proxy_path = "http://localhost:9862";

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Creating our Tardy instance that
    // will spawn our runtimes.
    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .auto,
    });
    defer t.deinit();

    var client = Client.init(allocator, .{});
    defer client.deinit();

    var router = Router.init(allocator);
    defer router.deinit();

    // TODO: we need a better solution for a general reroute on
    // all routes.

    try router.serve_route("/", Route.init().get(&client, struct {
        fn handler_fn(ctx: *Context, c: *Client) !void {
            var req = try c.get(ctx.runtime, proxy_path);
            try req.fetch(ctx, fetch_task);
        }
    }.handler_fn));

    try router.serve_route("/%r", Route.init().get(&client, struct {
        fn handler_fn(ctx: *Context, c: *Client) !void {
            const path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ proxy_path, ctx.path });
            var req = try c.get(ctx.runtime, path);
            try req.fetch(ctx, fetch_task);
        }
    }.handler_fn));

    try t.entry(
        &router,
        struct {
            fn entry(rt: *Runtime, r: *const Router) !void {
                var server = Server.init(rt.allocator, .{});
                try server.bind(.{ .ip = .{ .host = host, .port = port } });
                try server.serve(r, rt);

                // this kills it after a set delay, allowing the GPA to report any leaks.
                //try rt.spawn_delay(void, {}, struct {
                //    fn kill_task(runtime: *Runtime, _: void, _: void) !void {
                //        runtime.stop();
                //    }
                //}.kill_task, .{ .seconds = 30 });
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
