const std = @import("std");
const log = std.log.scoped(.@"zzz/http/request");
const assert = std.debug.assert;

const Headers = @import("lib.zig").Headers;
const HTTPError = @import("lib.zig").HTTPError;
const Method = @import("lib.zig").Method;

pub const Request = struct {
    allocator: std.mem.Allocator,
    method: Method,
    path: []const u8,
    version: std.http.Version = .@"HTTP/1.1",
    headers: Headers,
    body: []const u8,

    /// This is for constructing a Request.
    pub fn init(allocator: std.mem.Allocator, header_count_max: usize) !Request {
        var headers = Headers{};
        try headers.ensureUnusedCapacity(allocator, header_count_max);

        return Request{
            .allocator = allocator,
            .headers = headers,
            .method = undefined,
            .path = undefined,
            .body = undefined,
        };
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit(self.allocator);
    }

    const RequestParseOptions = struct {
        request_bytes_max: u32,
        request_uri_bytes_max: u32,
    };

    pub fn parse_headers(self: *Request, bytes: []const u8, options: RequestParseOptions) HTTPError!void {
        self.headers.clearRetainingCapacity();
        var total_size: u32 = 0;
        var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");

        if (lines.peek() == null) {
            return HTTPError.MalformedRequest;
        }

        var parsing_first_line = true;
        while (lines.next()) |line| {
            total_size += @intCast(line.len);

            if (total_size > options.request_bytes_max) {
                return HTTPError.ContentTooLarge;
            }

            if (parsing_first_line) {
                var chunks = std.mem.tokenizeScalar(u8, line, ' ');

                const method_string = chunks.next() orelse return HTTPError.MalformedRequest;
                const method = Method.parse(method_string) catch {
                    log.warn("invalid method: {s}", .{method_string});
                    return HTTPError.InvalidMethod;
                };

                const uri_string = chunks.next() orelse return HTTPError.MalformedRequest;
                if (uri_string.len >= options.request_uri_bytes_max) return HTTPError.URITooLong;
                if (uri_string[0] != '/') return HTTPError.MalformedRequest;

                const version_string = chunks.next() orelse return HTTPError.MalformedRequest;
                if (!std.mem.eql(u8, version_string, "HTTP/1.1")) return HTTPError.HTTPVersionNotSupported;
                self.set(.{ .method = method, .path = uri_string });

                // There shouldn't be anything else.
                if (chunks.next() != null) return HTTPError.MalformedRequest;

                parsing_first_line = false;
            } else {
                var header_iter = std.mem.tokenizeScalar(u8, line, ':');
                const key = header_iter.next() orelse return HTTPError.MalformedRequest;
                const value = std.mem.trimLeft(u8, header_iter.rest(), &.{' '});
                if (value.len == 0) return HTTPError.MalformedRequest;

                if (self.headers.count() >= self.headers.capacity() / 2) return HTTPError.TooManyHeaders;
                self.headers.putAssumeCapacity(key, value);
            }
        }
    }

    pub const RequestSetOptions = struct {
        method: ?Method = null,
        path: ?[]const u8 = null,
        body: ?[]const u8 = null,
    };

    pub fn set(self: *Request, options: RequestSetOptions) void {
        if (options.method) |method| {
            self.method = method;
        }

        if (options.path) |path| {
            self.path = path;
        }

        if (options.body) |body| {
            self.body = body;
        }
    }

    /// Should this specific Request expect to capture a body.
    pub fn expect_body(self: Request) bool {
        return switch (self.method) {
            .POST, .PUT, .PATCH => true,
            .GET, .HEAD, .DELETE, .CONNECT, .OPTIONS, .TRACE => false,
        };
    }

    pub fn headers_into_buffer(self: *Request, buffer: []u8, content_length: ?usize) ![]u8 {
        var index: usize = 0;

        // Method
        std.mem.copyForwards(u8, buffer[index..], @tagName(self.method));
        index += @tagName(self.method).len;
        buffer[index] = ' ';
        index += 1;

        // Request URI
        std.mem.copyForwards(u8, buffer[index..], self.path);
        index += self.path.len;
        buffer[index] = ' ';
        index += 1;

        // HTTP Version
        std.mem.copyForwards(u8, buffer[index..], "HTTP/1.1\r\n");
        index += 10;

        std.mem.copyForwards(u8, buffer[index..], "Connection: keep-alive\r\n");
        index += 24;

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

test "Request: Parse" {
    const request_text =
        \\GET / HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    var request = try Request.init(testing.allocator, 32);
    defer request.deinit();

    try request.parse_headers(request_text[0..], .{
        .request_bytes_max = 1024,
        .request_uri_bytes_max = 256,
    });

    try testing.expectEqual(.GET, request.method);
    try testing.expectEqualStrings("/", request.path);
    try testing.expectEqual(.@"HTTP/1.1", request.version);

    try testing.expectEqualStrings("localhost:9862", request.headers.get("Host").?);
    try testing.expectEqualStrings("keep-alive", request.headers.get("Connection").?);
    try testing.expectEqualStrings("text/html", request.headers.get("Accept").?);
}

test "Request: Expect ContentTooLong Error" {
    const request_text_format =
        \\GET {s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    const request_text = std.fmt.comptimePrint(request_text_format, .{[_]u8{'a'} ** 4096});
    var request = try Request.init(testing.allocator, 32);
    defer request.deinit();

    const err = request.parse_headers(request_text[0..], .{
        .request_bytes_max = 128,
        .request_uri_bytes_max = 64,
    });
    try testing.expectError(HTTPError.ContentTooLarge, err);
}

test "Request: Expect URITooLong Error" {
    const request_text_format =
        \\GET {s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    const request_text = std.fmt.comptimePrint(request_text_format, .{[_]u8{'a'} ** 4096});
    var request = try Request.init(testing.allocator, 32);
    defer request.deinit();

    const err = request.parse_headers(request_text[0..], .{
        .request_bytes_max = 1024 * 1024,
        .request_uri_bytes_max = 2048,
    });
    try testing.expectError(HTTPError.URITooLong, err);
}

test "Request: Expect Malformed when URI missing /" {
    const request_text_format =
        \\GET {s} HTTP/1.1
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    const request_text = std.fmt.comptimePrint(request_text_format, .{[_]u8{'a'} ** 256});
    var request = try Request.init(testing.allocator, 32);
    defer request.deinit();

    const err = request.parse_headers(request_text[0..], .{
        .request_bytes_max = 1024,
        .request_uri_bytes_max = 512,
    });
    try testing.expectError(HTTPError.MalformedRequest, err);
}

test "Request: Expect Incorrect HTTP Version" {
    const request_text =
        \\GET / HTTP/1.4
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    var request = try Request.init(testing.allocator, 32);
    defer request.deinit();

    const err = request.parse_headers(request_text[0..], .{
        .request_bytes_max = 1024,
        .request_uri_bytes_max = 512,
    });
    try testing.expectError(HTTPError.HTTPVersionNotSupported, err);
}

test "Request: Malformed Headers" {
    const request_text =
        \\GET / HTTP/1.1
        \\Host: localhost:9862
        \\Connection:
        \\Accept: text/html
    ;

    var request = try Request.init(testing.allocator, 32);
    defer request.deinit();

    const err = request.parse_headers(request_text[0..], .{
        .request_bytes_max = 1024,
        .request_uri_bytes_max = 512,
    });
    try testing.expectError(HTTPError.MalformedRequest, err);
}

test "Request: Generate Headers" {
    var buffer: [512]u8 = undefined;

    var request = try Request.init(testing.allocator, 32);
    defer request.deinit();

    request.set(.{
        .path = "/",
        .method = .GET,
        .body = null,
    });

    const headers = try request.headers_into_buffer(buffer[0..], 0);

    const expected = "GET / HTTP/1.1\r\nConnection: keep-alive\r\nContent-Length: 0\r\n\r\n";
    try testing.expectEqualStrings(expected, headers);
}
