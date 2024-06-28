const std = @import("std");
const Header = @import("header.zig").Header;
const stdout = std.io.getStdOut().writer();

var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
var allocator = arena.allocator();

pub fn main() !void {
    defer arena.deinit();

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
                defer connection.stream.close();
                var stream = connection.stream;

                var buffer: [1024]u8 = undefined;
                var buf = std.io.bufferedReader(stream.reader());
                const msg = try buf.reader().readUntilDelimiter(&buffer, '\n');

                var head = Header.init(allocator);
                defer head.deinit();
                try head.parse(msg);
                try stream.writeAll("HTTP/1.0 200 OK");
            }
        }.thread_request, .{conn});
        thread.detach();
    } else |err| {
        try stdout.print("Connection Failed: {any}\n", .{err});
    }
}
