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
    version: std.http.Version = .@"HTTP/1.1",
    headers: Headers,

    pub fn init(allocator: std.mem.Allocator, header_count_max: usize) !Response {
        var headers = Headers{};
        try headers.ensureUnusedCapacity(allocator, header_count_max);

        return Response{
            .allocator = allocator,
            .headers = headers,
        };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit(self.allocator);
    }

    pub fn clear(self: *Response) void {
        self.status = null;
        self.mime = null;
        self.body = null;
    }

    const ResponseParseOptions = struct { size_response_max: u32 };

    pub fn parse_headers(self: *Response, bytes: []const u8, options: ResponseParseOptions) !void {
        self.headers.clearRetainingCapacity();
        var total_size: u32 = 0;
        var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");

        if (lines.peek() == null) {
            return error.MalformedResponse;
        }

        var parsing_first_line = true;
        while (lines.next()) |line| {
            total_size += @intCast(line.len);

            if (total_size > options.size_response_max) {
                return error.ContentTooLarge;
            }

            if (parsing_first_line) {
                var chunks = std.mem.tokenizeScalar(u8, line, ' ');

                const version_string = chunks.next() orelse return error.MalformedResponse;
                if (!std.mem.eql(u8, version_string, "HTTP/1.1")) return error.HTTPVersionNotSupported;

                const status_string = chunks.next() orelse return error.MalformedResponse;
                const status: Status = @enumFromInt(try std.fmt.parseInt(u16, status_string, 10));
                self.set(.{ .status = status });

                parsing_first_line = false;
            } else {
                var header_iter = std.mem.tokenizeScalar(u8, line, ':');
                const key = header_iter.next() orelse return error.MalformedResponse;
                const value = std.mem.trimLeft(u8, header_iter.rest(), &.{' '});
                if (value.len == 0) return error.MalformedResponse;
                self.headers.putAssumeCapacity(key, value);
            }
        }

        if (self.headers.get("Content-Type")) |content| {
            self.set(.{
                .mime = Mime.from_content_type(content),
            });
        }
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

const testing = std.testing;

test "Response: Parse" {
    const response_text =
        \\HTTP/1.1 200 OK
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    var response = try Response.init(testing.allocator, 32);
    defer response.deinit();

    try response.parse_headers(response_text[0..], .{
        .size_response_max = 1024,
    });

    try testing.expectEqual(.OK, response.status);
    try testing.expectEqual(.@"HTTP/1.1", response.version);

    try testing.expectEqualStrings("localhost:9862", response.headers.get("Host").?);
    try testing.expectEqualStrings("keep-alive", response.headers.get("Connection").?);
    try testing.expectEqualStrings("text/html", response.headers.get("Accept").?);
}

test "Response: Expect ContentTooLong Error" {
    const response_text_format =
        \\HTTP/1.1 200 {s}
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    const response_text = std.fmt.comptimePrint(response_text_format, .{[_]u8{'a'} ** 4096});
    var response = try Response.init(testing.allocator, 32);
    defer response.deinit();

    const err = response.parse_headers(response_text[0..], .{
        .size_response_max = 128,
    });
    try testing.expectError(error.ContentTooLarge, err);
}

test "Response: Expect Incorrect HTTP Version" {
    const response_text =
        \\HTTP/1.4 200 OK
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    var response = try Response.init(testing.allocator, 32);
    defer response.deinit();

    const err = response.parse_headers(response_text[0..], .{
        .size_response_max = 1024,
    });
    try testing.expectError(error.HTTPVersionNotSupported, err);
}

test "Response: Malformed Headers" {
    const response_text =
        \\HTTP/1.1 200 OK
        \\Host: localhost:9862
        \\Connection:
        \\Accept: text/html
    ;

    var response = try Response.init(testing.allocator, 32);
    defer response.deinit();

    const err = response.parse_headers(response_text[0..], .{
        .size_response_max = 1024,
    });
    try testing.expectError(error.MalformedResponse, err);
}

test "Response: Generate Headers" {
    var buffer: [512]u8 = undefined;

    var response = try Response.init(testing.allocator, 32);
    defer response.deinit();

    response.set(.{
        .status = .OK,
        .mime = Mime.HTML,
    });

    const headers = try response.headers_into_buffer(buffer[0..], 0);

    const expected = "HTTP/1.1 200 OK\r\nServer: zzz\r\nConnection: keep-alive\r\nContent-Type: text/html\r\nContent-Length: 0\r\n\r\n";
    try testing.expectEqualStrings(expected, headers);
}
