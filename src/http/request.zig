const std = @import("std");
const log = std.log.scoped(.@"zzz/http/request");
const assert = std.debug.assert;

const Headers = @import("lib.zig").Headers;
const HTTPError = @import("lib.zig").HTTPError;
const Method = @import("lib.zig").Method;

pub const Request = struct {
    allocator: std.mem.Allocator,
    method: ?Method = null,
    uri: ?[]const u8 = null,
    version: ?std.http.Version = .@"HTTP/1.1",
    headers: Headers,
    body: ?[]const u8 = null,

    /// This is for constructing a Request.
    pub fn init(allocator: std.mem.Allocator, header_count_max: usize) !Request {
        const headers = try Headers.init(allocator, header_count_max);

        return Request{
            .allocator = allocator,
            .headers = headers,
        };
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }

    pub fn clear(self: *Request) void {
        self.method = null;
        self.uri = null;
        self.body = null;
        self.headers.clear();
    }

    const RequestParseOptions = struct {
        request_bytes_max: u32,
        request_uri_bytes_max: u32,
    };

    pub fn parse_headers(self: *Request, bytes: []const u8, options: RequestParseOptions) HTTPError!void {
        self.clear();
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
                self.set(.{ .method = method, .uri = uri_string });

                // There shouldn't be anything else.
                if (chunks.next() != null) return HTTPError.MalformedRequest;

                parsing_first_line = false;
            } else {
                var header_iter = std.mem.tokenizeScalar(u8, line, ':');
                const key = header_iter.next() orelse return HTTPError.MalformedRequest;
                const value = std.mem.trimLeft(u8, header_iter.rest(), &.{' '});
                if (value.len == 0) return HTTPError.MalformedRequest;

                if (self.headers.num_clean() == 0) return HTTPError.TooManyHeaders;
                self.headers.put_assume_capacity(key, value);
            }
        }
    }

    pub const RequestSetOptions = struct {
        method: ?Method = null,
        uri: ?[]const u8 = null,
        body: ?[]const u8 = null,
    };

    pub fn set(self: *Request, options: RequestSetOptions) void {
        if (options.method) |method| {
            self.method = method;
        }

        if (options.uri) |uri| {
            self.uri = uri;
        }

        if (options.body) |body| {
            self.body = body;
        }
    }

    /// Should this specific Request expect to capture a body.
    pub fn expect_body(self: Request) bool {
        return switch (self.method orelse return false) {
            .POST, .PUT, .PATCH => true,
            .GET, .HEAD, .DELETE, .CONNECT, .OPTIONS, .TRACE => false,
        };
    }
};

const testing = std.testing;

test "Parse Request" {
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
    try testing.expectEqualStrings("/", request.uri.?);
    try testing.expectEqual(.@"HTTP/1.1", request.version);

    try testing.expectEqualStrings("localhost:9862", request.headers.get("Host").?);
    try testing.expectEqualStrings("keep-alive", request.headers.get("Connection").?);
    try testing.expectEqualStrings("text/html", request.headers.get("Accept").?);
}

test "Expect ContentTooLong Error" {
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

test "Expect URITooLong Error" {
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

test "Expect Malformed when URI missing /" {
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

test "Expect Incorrect HTTP Version" {
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

test "Malformed Headers" {
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
