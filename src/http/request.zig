const std = @import("std");
const log = std.log.scoped(.@"zzz/http/request");
const assert = std.debug.assert;

const Headers = @import("lib.zig").Headers;
const HTTPError = @import("lib.zig").HTTPError;
const Method = @import("lib.zig").Method;

const RequestOptions = struct {
    size_request_max: u32,
    size_request_uri_max: u32,
    num_header_max: u32,
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    size_request_max: u32,
    size_request_uri_max: u32,
    method: Method,
    uri: []const u8,
    version: std.http.Version,
    headers: Headers,
    body: []const u8,

    /// This is for constructing a Request.
    pub fn init(allocator: std.mem.Allocator, options: RequestOptions) !Request {
        // The request size needs to be larger than the max URI size.
        assert(options.size_request_max > options.size_request_uri_max);

        return Request{
            .allocator = allocator,
            .headers = try Headers.init(allocator, options.num_header_max),
            .size_request_max = options.size_request_max,
            .size_request_uri_max = options.size_request_uri_max,
            .method = undefined,
            .uri = undefined,
            .version = undefined,
            .body = undefined,
        };
    }

    pub fn deinit(self: *Request) void {
        self.headers.deinit();
    }

    pub fn parse_headers(self: *Request, bytes: []const u8) HTTPError!void {
        self.headers.clear();
        var total_size: u32 = 0;
        var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");

        if (lines.peek() == null) {
            return HTTPError.MalformedRequest;
        }

        var parsing_first_line = true;
        while (lines.next()) |line| {
            total_size += @intCast(line.len);

            if (total_size > self.size_request_max) {
                return HTTPError.ContentTooLarge;
            }

            if (parsing_first_line) {
                var chunks = std.mem.tokenizeScalar(u8, line, ' ');

                const method_string = chunks.next() orelse return HTTPError.MalformedRequest;
                const method = Method.parse(method_string) catch {
                    log.warn("invalid method: {s}", .{method_string});
                    return HTTPError.InvalidMethod;
                };
                self.set_method(method);

                const uri_string = chunks.next() orelse return HTTPError.MalformedRequest;
                if (uri_string.len >= self.size_request_uri_max) return HTTPError.URITooLong;
                if (uri_string[0] != '/') return HTTPError.MalformedRequest;
                self.set_uri(uri_string);

                const version_string = chunks.next() orelse return HTTPError.MalformedRequest;
                if (!std.mem.eql(u8, version_string, "HTTP/1.1")) return HTTPError.HTTPVersionNotSupported;
                self.set_version(.@"HTTP/1.1");

                // There shouldn't be anything else.
                if (chunks.next() != null) return HTTPError.MalformedRequest;

                parsing_first_line = false;
            } else {
                var header_iter = std.mem.tokenizeScalar(u8, line, ':');
                const key = header_iter.next() orelse return HTTPError.MalformedRequest;
                const value = std.mem.trimLeft(u8, header_iter.rest(), &.{' '});
                if (value.len == 0) return HTTPError.MalformedRequest;
                try self.headers.add(key, value);
            }
        }
    }

    pub fn set_method(self: *Request, method: Method) void {
        self.method = method;
    }

    pub fn set_uri(self: *Request, uri: []const u8) void {
        self.uri = uri;
    }

    pub fn set_version(self: *Request, version: std.http.Version) void {
        self.version = version;
    }

    pub fn set_body(self: *Request, body: []const u8) void {
        self.body = body;
    }

    /// Should this specific Request expect to capture a body.
    pub fn expect_body(self: Request) bool {
        return switch (self.method) {
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

    var request = try Request.init(testing.allocator, .{
        .num_header_max = 32,
        .size_request_max = 1024,
        .size_request_uri_max = 256,
    });
    defer request.deinit();

    try request.parse_headers(request_text[0..]);

    try testing.expectEqual(.GET, request.method);
    try testing.expectEqualStrings("/", request.uri);
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
    var request = try Request.init(testing.allocator, .{
        .num_header_max = 32,
        .size_request_max = 128,
        .size_request_uri_max = 64,
    });
    defer request.deinit();

    const err = request.parse_headers(request_text[0..]);
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
    var request = try Request.init(testing.allocator, .{
        .num_header_max = 32,
        .size_request_max = 1024 * 1024,
        .size_request_uri_max = 2048,
    });
    defer request.deinit();

    const err = request.parse_headers(request_text[0..]);
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
    var request = try Request.init(testing.allocator, .{
        .num_header_max = 32,
        .size_request_max = 1024,
        .size_request_uri_max = 512,
    });
    defer request.deinit();

    const err = request.parse_headers(request_text[0..]);
    try testing.expectError(HTTPError.MalformedRequest, err);
}

test "Expect Incorrect HTTP Version" {
    const request_text =
        \\GET / HTTP/1.4
        \\Host: localhost:9862
        \\Connection: keep-alive
        \\Accept: text/html
    ;

    var request = try Request.init(testing.allocator, .{
        .num_header_max = 32,
        .size_request_max = 1024,
        .size_request_uri_max = 512,
    });
    defer request.deinit();

    const err = request.parse_headers(request_text[0..]);
    try testing.expectError(HTTPError.HTTPVersionNotSupported, err);
}

test "Malformed Headers" {
    const request_text =
        \\GET / HTTP/1.1
        \\Host: localhost:9862
        \\Connection:
        \\Accept: text/html
    ;

    var request = try Request.init(testing.allocator, .{
        .num_header_max = 32,
        .size_request_max = 1024,
        .size_request_uri_max = 512,
    });
    defer request.deinit();

    const err = request.parse_headers(request_text[0..]);
    try testing.expectError(HTTPError.MalformedRequest, err);
}
