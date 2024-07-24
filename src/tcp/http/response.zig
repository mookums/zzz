const std = @import("std");
const assert = std.debug.assert;

const KVPair = @import("lib.zig").KVPair;
const Status = @import("lib.zig").Status;
const Mime = @import("lib.zig").Mime;

pub const Response = struct {
    status: Status,
    mime: ?Mime = null,
    body: []const u8 = undefined,
    headers: [32]KVPair = [_]KVPair{undefined} ** 32,
    headers_idx: usize = 0,

    pub fn init(status: Status, mime: ?Mime, body: []const u8) Response {
        return Response{
            .status = status,
            .mime = mime,
            .body = body,
        };
    }

    pub fn add_header(self: *Response, kv: KVPair) !void {
        // Ensure that we don't have the colon since we add it back later.
        //assert(std.mem.indexOfScalar(u8, kv.key, ':') == null);
        //assert(std.mem.indexOfScalar(u8, kv.value, ':') == null);

        if (self.headers_idx < self.headers.len) {
            self.headers[self.headers_idx] = kv;
            self.headers_idx += 1;
        } else {
            return error.TooManyHeaders;
        }
    }

    pub fn respond_into_buffer(self: Response, buffer: []u8) ![]u8 {
        var stream = std.io.fixedBufferStream(buffer);
        try self.respond(stream.writer(), self.body, self.mime);
        return stream.getWritten();
    }

    pub fn respond_into_alloc(self: Response, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        var stream = std.io.fixedBufferStream(try allocator.alloc(u8, max_size));
        try self.respond(stream.writer(), self.body, self.mime);
        return stream.getWritten();
    }

    /// Writes this response to the given Writer. This is assumed to be a BufferedWriter
    /// for the TCP stream.
    pub fn respond(self: Response, writer: anytype, body: ?[]const u8, mime: ?Mime) !void {
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
        } else {
            // By default, we should just send as an octet-stream for safety.
            try writer.writeAll("Content-Type: ");
            try writer.writeAll(Mime.BIN.content_type);
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
