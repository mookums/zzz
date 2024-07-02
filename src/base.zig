const std = @import("std");

pub fn main() !void {
    const addr = try std.net.Address.resolveIp("127.0.0.1", 9862);
    var server = try addr.listen(.{ .reuse_port = true });
    defer server.deinit();

    while (true) {
        const connection = server.accept() catch continue;
        var http_buffer: [2048]u8 = undefined;
        var http = std.http.Server.init(connection, &http_buffer);

        while (true) {
            var request = http.receiveHead() catch break;

            const file = @embedFile("./sample.html");
            try request.respond(file, .{ .status = .ok });
        }
    }
}
