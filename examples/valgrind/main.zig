const std = @import("std");
const log = std.log.scoped(.@"examples/valgrind");
const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .single,
    });
    defer t.deinit();

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, struct {
            pub fn handler_fn(ctx: *Context, _: void) !void {
                const body =
                    \\ <!DOCTYPE html>
                    \\ <html>
                    \\ <body>
                    \\ <h1>Hello, World!</h1>
                    \\ </body>
                    \\ </html>
                ;
                return try ctx.respond(.{
                    .status = .OK,
                    .mime = http.Mime.HTML,
                    .body = body[0..],
                });
            }
        }.handler_fn).layer(),

        Route.init("/kill").get({}, struct {
            pub fn handler_fn(ctx: *Context, _: void) !void {
                ctx.runtime.stop();
            }
        }.handler_fn).layer(),
    }, .{});
    defer router.deinit(allocator);
    router.print_route_tree();

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
