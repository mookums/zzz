const std = @import("std");
const assert = std.debug.assert;

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

    pub fn init(allocator: std.mem.Allocator, options: ResponseOptions) !Response {
        return Response{
            .allocator = allocator,
            .headers = try Headers.init(allocator, options.num_headers_max),
            .cached_date = CachedDate{
                .buffer = try allocator.alloc(u8, 32),
                .index = 0,
                .ts = 0,
            },
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

    pub fn set_body(self: *Response, body: []const u8) void {
        self.body = body;
    }

    pub fn clear(self: *Response) void {
        self.status = null;
        self.mime = null;
        self.body = null;
    }

    pub const ResponseSetOptions = struct {
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

    pub fn headers_into_buffer(self: *Response, buffer: []u8, content_length: ?u32) ![]u8 {
        var index: usize = 0;

        // Status Line
        std.mem.copyForwards(u8, buffer[index..], "HTTP/1.1 ");
        index += 9;

        if (self.status) |status| {
            const status_code = @intFromEnum(status);
            const code = try std.fmt.bufPrint(buffer[index..], "{d} ", .{status_code});
            index += code.len;
            const status_name = @tagName(status);
            std.mem.copyForwards(u8, buffer[index..], status_name);
            index += status_name.len;
        } else {
            return error.MissingStatus;
        }

        std.mem.copyForwards(u8, buffer[index..], "\r\n");
        index += 2;

        // Standard Headers
        // Cache the Date
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
            std.mem.copyForwards(u8, buffer[index..], "Date: ");
            index += 6;
            std.mem.copyForwards(u8, buffer[index..], self.cached_date.buffer[0..self.cached_date.index]);
            index += self.cached_date.index;
            std.mem.copyForwards(u8, buffer[index..], "\r\n");
            index += 2;
        }

        std.mem.copyForwards(u8, buffer[index..], "Server: zzz\r\nConnection: keep-alive\r\n");
        index += 37;

        // Headers
        var iter = self.headers.map.iterator();
        while (iter.next()) |entry| {
            std.mem.copyForwards(u8, buffer[index..], entry.key_ptr.*);
            index += entry.key_ptr.len;
            std.mem.copyForwards(u8, buffer[index..], ": ");
            index += 2;
            std.mem.copyForwards(u8, buffer[index..], entry.value_ptr.*);
            index += entry.value_ptr.len;
            std.mem.copyForwards(u8, buffer[index..], "\r\n");
            index += 2;
        }

        // Content-Type
        std.mem.copyForwards(u8, buffer[index..], "Content-Type: ");
        index += 14;
        if (self.mime) |m| {
            std.mem.copyForwards(u8, buffer[index..], m.content_type);
            index += m.content_type.len;
        } else {
            std.mem.copyForwards(u8, buffer[index..], Mime.BIN.content_type);
            index += Mime.BIN.content_type.len;
        }
        std.mem.copyForwards(u8, buffer[index..], "\r\n");
        index += 2;

        // Content-Length
        if (content_length) |length| {
            std.mem.copyForwards(u8, buffer[index..], "Content-Length: ");
            index += 16;
            const length_str = try std.fmt.bufPrint(buffer[index..], "{d}", .{length});
            index += length_str.len;
            std.mem.copyForwards(u8, buffer[index..], "\r\n");
            index += 2;
        }

        std.mem.copyForwards(u8, buffer[index..], "\r\n");
        index += 2;

        return buffer[0..index];
    }
};
