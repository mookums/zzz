const std = @import("std");
const assert = std.debug.assert;

const KVPair = @import("lib.zig").KVPair;
const Status = @import("lib.zig").Status;
const Mime = @import("lib.zig").Mime;

pub const Response = struct {
    status: Status,
    mime: ?Mime = null,
    body: []const u8 = undefined,
    header_pairs: [32]KVPair = [_]KVPair{undefined} ** 32,
    headers_idx: u32 = 0,

    pub fn init(status: Status, mime: ?Mime, body: []const u8) Response {
        return Response{
            .status = status,
            .mime = mime,
            .body = body,
        };
    }

    pub fn add_header(self: *Response, kv: KVPair) !void {
        // Ensure that we don't have the colon since we add it back later.
        assert(std.mem.indexOfScalar(u8, kv.key, ':') == null);

        if (self.headers_idx < self.header_pairs.len) {
            self.header_pairs[self.headers_idx] = kv;
            self.headers_idx += 1;
        } else {
            return error.TooManyHeaders;
        }
    }

    pub fn headers_into_buffer(self: Response, buffer: []u8, content_length: u32) ![]u8 {
        var stream = std.io.fixedBufferStream(buffer);
        try self.write_headers(stream.writer(), content_length);
        return stream.getWritten();
    }

    fn write_headers(self: Response, writer: anytype, content_length: u32) !void {
        // Status Line
        try writer.writeAll("HTTP/1.1 ");
        try std.fmt.formatInt(@intFromEnum(self.status), 10, .lower, .{}, writer);
        try writer.writeAll(" ");
        try writer.writeAll(@tagName(self.status));
        try writer.writeAll("\r\n");

        // Standard Headers.
        try writer.writeAll("Server: zzz (z3)\r\n");
        try writer.writeAll("Connection: keep-alive\r\n");

        // Headers
        for (0..self.headers_idx) |i| {
            const h = self.header_pairs[i];
            try writer.writeAll(h.key);
            try writer.writeAll(": ");
            try writer.writeAll(h.value);
            try writer.writeAll("\r\n");
        }

        // If we have an associated MIME type.
        if (self.mime) |m| {
            try writer.writeAll("Content-Type: ");
            try writer.writeAll(m.content_type);
            try writer.writeAll("\r\n");
        } else {
            // By default, we should just send as an octet-stream for safety.
            try writer.writeAll("Content-Type: ");
            try writer.writeAll(Mime.BIN.content_type);
            try writer.writeAll("\r\n");
        }

        try writer.writeAll("Content-Length: ");
        try std.fmt.formatInt(content_length, 10, .lower, .{}, writer);
        try writer.writeAll("\r\n");
        try writer.writeAll("\r\n");
    }
};
