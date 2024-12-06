const std = @import("std");
const log = std.log.scoped(.@"examples/benchmark");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Server = http.Server(.plain);
const Context = Server.Context;
const Route = Server.Route;
const Router = Server.Router;

pub const std_options = .{
    .log_level = .err,
};

pub fn root_handler(ctx: *Context, _: void) !void {
    try ctx.respond(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = "This is an HTTP benchmark",
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .auto,
    });
    defer t.deinit();

    var router = Router.init(allocator);
    defer router.deinit();

    try router.serve_route("/", Route.init().get({}, root_handler));

    try t.entry(
        &router,
        struct {
            fn entry(rt: *Runtime, r: *const Router) !void {
                var server = Server.init(rt.allocator, .{});
                try server.bind(.{ .unix = "/tmp/zzz.sock" });
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
