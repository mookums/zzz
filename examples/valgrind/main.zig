const std = @import("std");
const log = std.log.scoped(.@"examples/valgrind");
const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Server = http.Server(.plain, void);
const Router = Server.Router;
const Context = Server.Context;
const Route = Server.Route;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){ .backing_allocator = std.heap.c_allocator };
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = Router.init({}, &[_]Route{
        Route.init("/").get(struct {
            pub fn handler_fn(ctx: *Context) !void {
                const body =
                    \\ <!DOCTYPE html>
                    \\ <html>
                    \\ <body>
                    \\ <h1>Hello, World!</h1>
                    \\ </body>
                    \\ </html>
                ;
                try ctx.respond(.{
                    .status = .OK,
                    .mime = http.Mime.HTML,
                    .body = body[0..],
                });
            }
        }.handler_fn),

        Route.init("/kill").get(struct {
            pub fn handler_fn(ctx: *Context) !void {
                ctx.runtime.stop();
            }
        }.handler_fn),
    }, .{});

    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .single,
    });
    defer t.deinit();

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
