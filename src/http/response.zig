const std = @import("std");
const assert = std.debug.assert;

const Cookie = @import("cookie.zig").Cookie;
const CookieMap = @import("cookie.zig").CookieMap;
const Headers = @import("lib.zig").Headers;
const Status = @import("lib.zig").Status;
const Mime = @import("lib.zig").Mime;
const Date = @import("lib.zig").Date;

const ResponseOptions = struct {
    num_headers_max: u32,
};

const CachedDate = struct {
    buffer: []u8,
    ts: i64,
    index: usize,
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: ?Status = null,
    mime: ?Mime = null,
    body: ?[]const u8 = null,
    headers: Headers,
    cached_date: CachedDate,
    cookies: std.ArrayList(Cookie),

    pub fn init(allocator: std.mem.Allocator, options: ResponseOptions) !Response {
        return Response{
            .allocator = allocator,
            .headers = try Headers.init(allocator, options.num_headers_max),
            .cached_date = CachedDate{
                .buffer = try allocator.alloc(u8, 32),
                .index = 0,
                .ts = 0,
            },
            .cookies = std.ArrayList(Cookie).init(allocator),
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
        self.allocator.free(self.cached_date.buffer);
    }

    pub fn set_status(self: *Response, status: Status) void {
        self.status = status;
    }

    pub fn set_mime(self: *Response, mime: Mime) void {
        self.mime = mime;
    }

    pub fn set_cookie(self: *Response, cookie: Cookie) void {
        self.cookies.append(cookie) catch |err| {
            std.debug.print("Could not add cookie: {}", .{err});
            return;
        };
    }

    pub fn set_body(self: *Response, body: []const u8) void {
        self.body = body;
    }

    pub fn clear(self: *Response) void {
        self.status = null;
        self.mime = null;
        self.body = null;
    }

    const ResponseSetOptions = struct {
        status: ?Status = null,
        mime: ?Mime = null,
        body: ?[]const u8 = null,
    };

    pub fn set(self: *Response, options: ResponseSetOptions) void {
        if (options.status) |status| {
            self.status = status;
        }

        if (options.mime) |mime| {
            self.mime = mime;
        }

        if (options.body) |body| {
            self.body = body;
        }
    }

    pub fn headers_into_buffer(self: *Response, buffer: []u8, content_length: u32) ![]u8 {
        var stream = std.io.fixedBufferStream(buffer);
        try self.write_headers(stream.writer(), content_length);
        return stream.getWritten();
    }

    fn write_headers(self: *Response, writer: anytype, content_length: u32) !void {
        // Status Line
        try writer.writeAll("HTTP/1.1 ");

        if (self.status) |status| {
            try std.fmt.formatInt(@intFromEnum(status), 10, .lower, .{}, writer);
            try writer.writeAll(" ");
            try writer.writeAll(@tagName(status));
        } else {
            return error.MissingStatus;
        }

        for (self.cookies.items) |cookie| {
            const cookie_str = try CookieMap.formatSetCookie(cookie, self.allocator);
            defer self.allocator.free(cookie_str);
            try writer.print("Set-Cookie: {s}\r\n", .{cookie_str});
        }

        try writer.writeAll("\r\n");

        // Standard Headers.

        // Cache the Date.
        // Omits the Date header on any platform that doesn't support timestamp().
        const ts = std.time.timestamp();
        if (ts != 0) {
            if (self.cached_date.ts != ts) {
                const date = Date.init(ts).to_http_date();
                const buf = try date.into_buf(self.cached_date.buffer);
                self.cached_date = .{
                    .ts = ts,
                    .buffer = self.cached_date.buffer,
                    .index = buf.len,
                };
            }

            assert(self.cached_date.index < self.cached_date.buffer.len);
            try writer.writeAll("Date: ");
            try writer.writeAll(self.cached_date.buffer[0..self.cached_date.index]);
            try writer.writeAll("\r\n");
        }

        try writer.writeAll("Server: zzz\r\n");
        try writer.writeAll("Connection: keep-alive\r\n");

        // Headers
        var iter = self.headers.map.iterator();
        while (iter.next()) |entry| {
            try writer.writeAll(entry.key_ptr.*);
            try writer.writeAll(": ");
            try writer.writeAll(entry.value_ptr.*);
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
