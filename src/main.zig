const std = @import("std");
const Request = @import("request.zig").Request;
const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    const port: u16 = 9862;

    const addr = try std.net.Address.resolveIp("127.0.0.1", port);
    try stdout.print("Starting Z3 Server...\n", .{});
    var server = try addr.listen(.{ .reuse_port = true });
    defer server.deinit();

    try stdout.print("Started Z3 Server. (Port: {d})\n", .{port});

    while (std.net.Server.accept(&server)) |conn| {
        try stdout.print("Connection Accepted (Addr: {any})\n", .{conn.address});
        const thread = try std.Thread.spawn(.{}, struct {
            fn thread_request(connection: std.net.Server.Connection) !void {
                var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                const allocator = arena.allocator();
                defer arena.deinit();
                defer connection.stream.close();

                // Basically, the stream will be passed around from request and response.
                var stream = connection.stream;

                var request = Request.init(allocator);
                try request.parse(stream);

                const file = @embedFile("./sample.html");
                try stream.writeAll("HTTP/1.0 200 OK\r\n\r\n");
                try stream.writeAll(file);
            }
        }.thread_request, .{conn});
        thread.detach();
    } else |err| {
        try stdout.print("Connection Failed: {any}\n", .{err});
    }
}
