const std = @import("std");
const RequestLine = @import("request_line.zig").RequestLine;

pub const Request = struct {
    allocator: std.mem.Allocator,
    request_line: RequestLine = undefined,
    headers: std.StringHashMap([]const u8),
    body: []u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) Request {
        return Request{
            .allocator = allocator,
            .headers = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn parse(self: *Request, stream: std.net.Stream) !void {
        var buf = std.io.bufferedReader(stream.reader());
        const request_line_msg = try buf.reader().readUntilDelimiterAlloc(self.allocator, '\n', 1024);

        var request_line = RequestLine.init(request_line_msg);
        try request_line.parse();

        headers: while (true) {
            // Read out each line, parsing the header.
            const header_line_msg = try buf.reader().readUntilDelimiterAlloc(self.allocator, '\n', 1024);

            // Breaks when we hit the body of the request.
            // Minimum header length is 3.
            if (header_line_msg.len < 3) {
                break :headers;
            }

            var split = std.mem.splitScalar(u8, header_line_msg, ':');
            try self.headers.put(split.first(), std.mem.trim(u8, split.next().?, &std.ascii.whitespace));
            std.debug.print("Header Line --> {s}\n", .{header_line_msg});
        }

        std.debug.print("Headers: \n", .{});
        var header_iter = self.headers.iterator();
        while (header_iter.next()) |entry| {
            std.debug.print("{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Remaining stream is the body.
        // We will be IGNORING trailers.
    }
};
