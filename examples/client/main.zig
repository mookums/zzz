const std = @import("std");
const log = std.log.scoped(.@"examples/client");

const zzz = @import("zzz");
const http = zzz.HTTP;

const tardy = @import("tardy");
const Tardy = tardy.Tardy(.auto);
const Runtime = tardy.Runtime;

const Client = http.Client;

fn fetch_task(rt: *Runtime, response: http.Response, _: void) !void {
    _ = rt;
    _ = response;
    log.debug("fetched and ran after!", .{});
}

pub fn main() !void {
    //var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    //const allocator = gpa.allocator();
    //defer _ = gpa.deinit();
    const allocator = std.heap.page_allocator;

    // Creating our Tardy instance that
    // will spawn our runtimes.
    var t = try Tardy.init(.{
        .allocator = allocator,
        .threading = .single,
    });
    defer t.deinit();

    var client = Client.init(allocator, .{});
    defer client.deinit();

    // This provides the entry function into the Tardy runtime. This will run
    // exactly once inside of each runtime (each thread gets a single runtime).
    try t.entry(
        &client,
        struct {
            fn entry(rt: *Runtime, c: *Client) !void {
                var req = try c.get(rt, "localhost:9292");
                try req.fetch();
            }
        }.entry,
        {},
        struct {
            fn exit(_: *Runtime, _: void) !void {}
        }.exit,
    );
}
