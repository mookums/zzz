const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/sse");

const tardy = zzz.tardy;
const Runtime = tardy.Runtime;
const Task = tardy.Task;

fn sse_process(rt: *Runtime, _: *const Task, c: ?*anyopaque) !void {
    try rt.spawn_delay(.{
        .func = sse_send,
        .ctx = c,
        .timespec = .{ .seconds = 1 },
    });
}

fn sse_send(_: *Runtime, _: *const Task, c: ?*anyopaque) !void {
    const context: *http.Context = @ptrCast(@alignCast(c));
    context.raw_send("data: hi!\n\n", sse_process);
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = http.Router.init(allocator);
    defer router.deinit();

    try router.serve_embedded_file("/", http.Mime.HTML, @embedFile("index.html"));
    try router.serve_sse_endpoint("/stream", sse_process);

    var server = http.Server(.plain, .auto).init(.{
        .router = &router,
        .allocator = allocator,
        .threading = .single,
    });
    defer server.deinit();

    try server.bind(host, port);
    try server.listen();
}
