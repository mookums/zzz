const std = @import("std");
const builtin = @import("builtin");
const Request = @import("request.zig").Request;
const RequestLine = @import("request_line.zig").RequestLine;

const ThreadManagers = @import("thread_manager.zig");

const StreamIterator = @import("stream_iterator.zig").StreamIterator;

const stdout = std.io.getStdOut().writer();

const ZZZ_VERSION = "0.1.0";

pub fn main() !void {
    const port: u16 = 9862;

    const addr = try std.net.Address.resolveIp("127.0.0.1", port);
    try stdout.print("Starting Z3 Server...\n", .{});
    var server = try addr.listen(.{ .reuse_port = true, .force_nonblocking = true });
    defer server.deinit();

    try stdout.print("Started Z3 Server. (Port: {d})\n", .{port});

    var manager = ThreadManagers.AtomicThreadManager.init(16);

    // Upper Event Loop.
    while (true) {
        // Ensures we can spawn.
        if (manager.canSpawn()) {
            // Use the non-blocking socket since connection is dictated by other means.
            const conn = std.net.Server.accept(&server) catch {
                continue;
            };

            try stdout.print("Connection Accepted (Addr: {any})\n", .{conn.address});
            //try stdout.print("Thread Count: {d}\n", .{manager.thread_count});

            manager.increment();

            const thread = try std.Thread.spawn(.{}, struct {
                fn thread_request(connection: std.net.Server.Connection, man: anytype) !void {
                    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    //const allocator = arena.allocator();
                    defer arena.deinit();
                    defer connection.stream.close();
                    defer man.decrement();

                    // Basically, the stream will be passed around from request and response.
                    var stream = connection.stream;

                    var bufReader = std.io.bufferedReader(stream.reader());
                    const reader = bufReader.reader();

                    //var request = Request.init(allocator);
                    //try request.parse(stream);

                    var buffer = [_]u8{0} ** 1024;
                    var splits = std.mem.splitScalar(u8, reader.readUntilDelimiter(&buffer, '\n') catch unreachable, ' ');

                    while (splits.next()) |split| {
                        std.debug.print("field: {s}\n", .{split});
                    }

                    //var iter = StreamIterator(u8, 1024).init(stream);

                    //if (iter.next(' ')) |method| {
                    //    std.debug.print("method: {s}\n", .{method});
                    //}

                    //if (iter.next(' ')) |host| {
                    //    std.debug.print("host: {s}\n", .{host});
                    //}

                    //if (iter.next('\n')) |version| {
                    //    std.debug.print("version: {s}\n", .{version});
                    //}

                    //// Why do these loop?
                    //if (iter.next(':')) |header| {
                    //    std.debug.print("header: {s}\n", .{header});
                    //}

                    //if (iter.next('\n')) |value| {
                    //    std.debug.print("value: {s}\n", .{value[1..]});
                    //}

                    const file = @embedFile("./sample.html");
                    stream.writeAll("HTTP/1.0 200 OK\n") catch return;
                    stream.writeAll("Server: zzz (z3) (" ++ ZZZ_VERSION ++ ")\n") catch return;
                    stream.writeAll("\r\n") catch return;
                    stream.writeAll(file) catch return;
                }
            }.thread_request, .{ conn, &manager });
            thread.detach();
        }
    }
}
