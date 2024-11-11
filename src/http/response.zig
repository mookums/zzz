const std = @import("std");
const assert = std.debug.assert;

const Headers = @import("lib.zig").Headers;
const Status = @import("lib.zig").Status;
const Mime = @import("lib.zig").Mime;
const Date = @import("lib.zig").Date;

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: ?Status = null,
    mime: ?Mime = null,
    body: ?[]const u8 = null,
    headers: Headers,

    pub fn init(allocator: std.mem.Allocator, num_header_max: u32) !Response {
        return Response{
            .allocator = allocator,
            .headers = try Headers.init(allocator, num_header_max),
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
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

        std.mem.copyForwards(u8, buffer[index..], "\r\nServer: zzz\r\nConnection: keep-alive\r\n");
        index += 39;

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
