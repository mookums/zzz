const std = @import("std");
const log = std.log.scoped(.@"examples/sse");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = @import("tardy");
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;
const Task = tardy.Task;
const Broadcast = tardy.Broadcast;
const Channel = tardy.Channel;

const Server = http.Server(.plain);
const Router = Server.Router;
const Context = Server.Context;
const Route = Server.Route;
const SSE = Server.SSE;

// When using SSE, you end up leaving the various abstractions that zzz has setup for you
// and you begin programming more against the tardy runtime.

const SSEBroadcastContext = struct {
    sse: *SSE,
    channel: *Channel(usize),
};

fn sse_send(_: *Runtime, value_opt: ?*const usize, ctx: *SSEBroadcastContext) !void {
    if (value_opt) |value| {
        const data = try std.fmt.allocPrint(
            ctx.sse.allocator,
            "value: {d}",
            .{value.*},
        );

        try ctx.sse.send(.{ .data = data }, ctx, sse_recv);
    } else {
        const broadcast = ctx.sse.runtime.storage.get_ptr("broadcast", Broadcast(usize));
        broadcast.unsubscribe(ctx.channel);
        try ctx.sse.context.close();
    }
}

fn sse_recv(_: *Runtime, success: bool, ctx: *SSEBroadcastContext) !void {
    if (success) {
        try ctx.channel.recv(ctx, sse_send);
    } else {
        log.debug("channel closed", .{});
        const broadcast = ctx.sse.runtime.storage.get_ptr("broadcast", Broadcast(usize));
        broadcast.unsubscribe(ctx.channel);
    }
}

fn sse_init(rt: *Runtime, success: bool, sse: *SSE) !void {
    if (!success) {
        // on failure, it'll auto close after
        // the sse initalization task runs.
        log.err("sse initalization failed", .{});
        return;
    }

    const broadcast = sse.runtime.storage.get_ptr("broadcast", Broadcast(usize));
    const context = try sse.allocator.create(SSEBroadcastContext);
    context.* = .{ .sse = sse, .channel = try broadcast.subscribe(rt, 10) };
    try context.channel.recv(context, sse_send);
}

fn sse_handler(ctx: *Context) void {
    log.debug("going into sse mode", .{});
    ctx.to_sse(sse_init) catch unreachable;
}

fn msg_handler(ctx: *Context) void {
    log.debug("message handler", .{});
    const broadcast = ctx.runtime.storage.get_ptr("broadcast", Broadcast(usize));
    broadcast.send(0) catch unreachable;
    ctx.respond(.{
        .status = .OK,
        .mime = http.Mime.HTML,
        .body = "",
    }) catch unreachable;
}

fn kill_handler(ctx: *Context) void {
    ctx.runtime.stop();
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;
    const max_conn = 512;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .{ .multi = 2 },
        .size_tasks_max = max_conn,
        .size_aio_jobs_max = max_conn,
        .size_aio_reap_max = max_conn,
    });
    defer t.deinit();

    var router = Router.init(allocator);
    defer router.deinit();

    try router.serve_embedded_file("/", http.Mime.HTML, @embedFile("index.html"));
    try router.serve_route("/kill", Route.init().get(kill_handler));
    try router.serve_route("/stream", Route.init().get(sse_handler));
    try router.serve_route("/message", Route.init().post(msg_handler));

    var broadcast = try Broadcast(usize).init(allocator, max_conn);
    defer broadcast.deinit();

    const EntryParams = struct {
        router: *const Router,
        broadcast: *Broadcast(usize),
    };

    try t.entry(
        struct {
            fn entry(rt: *Runtime, alloc: std.mem.Allocator, params: EntryParams) !void {
                try rt.storage.store_ptr("broadcast", params.broadcast);

                var server = Server.init(.{
                    .allocator = alloc,
                    .size_connections_max = max_conn,
                });

                try server.bind(host, port);
                try server.serve(params.router, rt);
            }
        }.entry,
        EntryParams{ .router = &router, .broadcast = &broadcast },
        struct {
            fn exit(rt: *Runtime, _: std.mem.Allocator, _: void) void {
                Server.clean(rt) catch unreachable;
            }
        }.exit,
        {},
    );
}
