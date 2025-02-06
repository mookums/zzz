const std = @import("std");
const assert = std.debug.assert;

const Headers = @import("lib.zig").Headers;
const Status = @import("lib.zig").Status;
const Mime = @import("lib.zig").Mime;
const Date = @import("lib.zig").Date;

const Stream = @import("tardy").Stream;

pub const Respond = union(enum) {
    pub const Fields = struct {
        status: Status = .OK,
        mime: Mime = Mime.TEXT,
        body: []const u8 = "",
        headers: []const [2][]const u8 = &.{},
    };

    // When we are returning a real HTTP request, we use this.
    standard: Fields,
    // If we responded and we want to give control back to the HTTP engine.
    responded,
    // If we want the connection to close.
    close,
};

pub const Response = struct {
    status: ?Status = null,
    mime: ?Mime = null,
    body: ?[]const u8 = null,
    headers: Headers,

    pub fn init(allocator: std.mem.Allocator, header_count_max: usize) !Response {
        const headers = try Headers.init(allocator, header_count_max);
        return Response{ .headers = headers };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
    }

    pub fn apply(self: *Response, into: Respond.Fields) !void {
        self.status = into.status;
        self.mime = into.mime;
        self.body = into.body;

        self.headers.clear();
        for (into.headers) |pair| try self.headers.put(pair[0], pair[1]);
    }

    pub fn clear(self: *Response) void {
        self.status = null;
        self.mime = null;
        self.body = null;
        self.headers.clear();
    }

    pub fn headers_into_buffer(self: *Response, buffer: []u8, content_length: ?usize) ![]u8 {
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
        var iter = self.headers.iterator();
        while (iter.next()) |entry| {
            std.mem.copyForwards(u8, buffer[index..], entry.key);
            index += entry.key.len;
            std.mem.copyForwards(u8, buffer[index..], ": ");
            index += 2;
            std.mem.copyForwards(u8, buffer[index..], entry.data);
            index += entry.data.len;
            std.mem.copyForwards(u8, buffer[index..], "\r\n");
            index += 2;
        }

        // Content-Type
        std.mem.copyForwards(u8, buffer[index..], "Content-Type: ");
        index += 14;
        if (self.mime) |m| {
            const content_type = switch (m.content_type) {
                .single => |inner| inner,
                .multiple => |content_types| content_types[0],
            };
            std.mem.copyForwards(u8, buffer[index..], content_type);
            index += content_type.len;
        } else {
            std.mem.copyForwards(u8, buffer[index..], Mime.BIN.content_type.single);
            index += Mime.BIN.content_type.single.len;
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
