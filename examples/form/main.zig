const std = @import("std");
const log = std.log.scoped(.@"examples/form");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = zzz.tardy;
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Socket = tardy.Socket;

const Server = http.Server;
const Router = http.Router;
const Context = http.Context;
const Route = http.Route;
const Form = http.Form;
const Query = http.Query;
const Respond = http.Respond;

fn base_handler(ctx: *const Context, _: void) !Respond {
    const body =
        \\<form>
        \\    <label for="fname">First name:</label>
        \\    <input type="text" id="fname" name="fname"><br><br>
        \\    <label for="lname">Last name:</label>
        \\    <input type="text" id="lname" name="lname"><br><br>
        \\    <label for="age">Age:</label>
        \\    <input type="text" id="age" name="age"><br><br>
        \\    <label for="height">Height:</label>
        \\    <input type="text" id="height" name="height"><br><br>
        \\    <button formaction="/generate" formmethod="get">GET Submit</button>
        \\    <button formaction="/generate" formmethod="post">POST Submit</button>
        \\</form> 
    ;

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = body,
    });
}

const UserInfo = struct {
    fname: []const u8,
    mname: []const u8 = "Middle",
    lname: []const u8,
    age: u8,
    height: f32,
    weight: ?[]const u8,
};

fn generate_handler(ctx: *const Context, _: void) !Respond {
    const info = switch (ctx.request.method.?) {
        .GET => try Query(UserInfo).parse(ctx.allocator, ctx),
        .POST => try Form(UserInfo).parse(ctx.allocator, ctx),
        else => return error.UnexpectedMethod,
    };

    const body = try std.fmt.allocPrint(
        ctx.allocator,
        "First: {s} | Middle: {s} | Last: {s} | Age: {d} | Height: {d} | Weight: {s}",
        .{
            info.fname,
            info.mname,
            info.lname,
            info.age,
            info.height,
            info.weight orelse "none",
        },
    );

    return ctx.response.apply(.{
        .status = .OK,
        .mime = http.Mime.TEXT,
        .body = body,
    });
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(allocator, .{ .threading = .auto });
    defer t.deinit();

    var router = try Router.init(allocator, &.{
        Route.init("/").get({}, base_handler).layer(),
        Route.init("/generate").get({}, generate_handler).post({}, generate_handler).layer(),
    }, .{});
    defer router.deinit(allocator);

    var socket = try Socket.init(.{ .tcp = .{ .host = host, .port = port } });
    defer socket.close_blocking();
    try socket.bind();
    try socket.listen(4096);

    const EntryParams = struct {
        router: *const Router,
        socket: Socket,
    };

    try t.entry(
        EntryParams{ .router = &router, .socket = socket },
        struct {
            fn entry(rt: *Runtime, p: EntryParams) !void {
                var server = Server.init(.{
                    .stack_size = 1024 * 1024 * 4,
                    .socket_buffer_bytes = 1024 * 2,
                });
                try server.serve(rt, p.router, .{ .normal = p.socket });
            }
        }.entry,
    );
}
