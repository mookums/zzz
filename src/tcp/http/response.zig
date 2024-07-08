const std = @import("std");
const assert = std.debug.assert;

const KVPair = @import("lib.zig").KVPair;
const Status = @import("lib.zig").Status;
const Mime = @import("lib.zig").Mime;

const ResponseOptions = struct {
    headers_size: usize = 32,
};

pub fn Response(comptime options: ResponseOptions) type {
    return struct {
        const Self = @This();
        status: Status,
        headers: [options.headers_size]KVPair = [_]KVPair{undefined} ** options.headers_size,
        headers_idx: usize = 0,

        pub fn init(status: Status) Self {
            return Self{ .status = status };
        }

        pub fn add_header(self: *Self, kv: KVPair) !void {
            // Ensure that we don't have the colon since we add it back later.
            //assert(std.mem.indexOfScalar(u8, kv.key, ':') == null);
            //assert(std.mem.indexOfScalar(u8, kv.value, ':') == null);

            if (self.headers_idx < options.headers_size) {
                self.headers[self.headers_idx] = kv;
                self.headers_idx += 1;
            } else {
                return error.TooManyHeaders;
            }
        }

        pub fn respond_into_buffer(self: *Self, buffer: []u8, body: []const u8, mime: ?Mime) ![]u8 {
            var stream = std.io.fixedBufferStream(buffer);
            try self.respond(stream.writer(), body, mime);
            return stream.getWritten();
        }

        pub fn respond_into_alloc(self: *Self, allocator: std.mem.Allocator, body: []const u8, mime: ?Mime, max_size: usize) ![]u8 {
            var stream = std.io.fixedBufferStream(try allocator.alloc(u8, max_size));
            try self.respond(stream.writer(), body, mime);
            return stream.getWritten();
        }

        /// Writes this response to the given Writer. This is assumed to be a BufferedWriter
        /// for the TCP stream.
        pub fn respond(self: *Self, writer: anytype, body: ?[]const u8, mime: ?Mime) !void {
            // Status Line
            try writer.writeAll("HTTP/1.1 ");
            try std.fmt.formatInt(@intFromEnum(self.status), 10, .lower, .{}, writer);
            try writer.writeAll(" ");
            try writer.writeAll(@tagName(self.status));
            try writer.writeAll("\r\n");

            // Standard Headers.
            try writer.writeAll("Server: zzz (z3)\r\n");
            //try writer.writeAll("Connection: close\r\n");

            // Headers
            for (0..self.headers_idx) |i| {
                const h = self.headers[i];
                try writer.writeAll(h.key);
                try writer.writeAll(": ");
                try writer.writeAll(h.value);
                try writer.writeAll("\r\n");
            }

            // If we have an associated MIME type.
            if (mime) |m| {
                try writer.writeAll("Content-Type: ");
                try writer.writeAll(m.content_type);
                try writer.writeAll("\r\n");
            }

            // If we are sending a body.
            if (body) |b| {
                try writer.writeAll("Content-Length: ");
                try std.fmt.formatInt(b.len, 10, .lower, .{}, writer);
                try writer.writeAll("\r\n");
                try writer.writeAll("\r\n");
                try writer.writeAll(b);
            }
        }
    };
}
