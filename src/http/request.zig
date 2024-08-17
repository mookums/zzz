const std = @import("std");
const assert = std.debug.assert;

const KVPair = @import("lib.zig").KVPair;
const HTTPError = @import("lib.zig").HTTPError;
const Method = @import("lib.zig").Method;

pub const Request = struct {
    size_request_max: u32,
    method: Method,
    host: []const u8,
    version: std.http.Version,
    headers: [32]KVPair = [_]KVPair{undefined} ** 32,
    body: []const u8,
    headers_idx: usize = 0,

    /// This is for constructing a Request.
    pub fn init(size_request_max: u32) Request {
        return Request{
            .size_request_max = size_request_max,
            .method = undefined,
            .host = undefined,
            .version = undefined,
            .body = undefined,
        };
    }

    pub fn parse_headers(self: *Request, bytes: []const u8) HTTPError!void {
        self.clear_headers();
        var total_size: u32 = 0;
        var line_iter = std.mem.tokenizeAny(u8, bytes, "\r\n");

        var parsing_first_line = true;
        while (line_iter.next()) |line| {
            total_size += @intCast(line.len);

            if (total_size > self.size_request_max) {
                return HTTPError.ContentTooLarge;
            }

            if (parsing_first_line) {
                var space_iter = std.mem.tokenizeScalar(u8, line, ' ');

                const method_string = space_iter.next() orelse return HTTPError.MalformedRequest;
                const method = Method.parse(method_string) catch {
                    return HTTPError.MalformedRequest;
                };
                self.set_method(method);

                const host_string = space_iter.next() orelse return HTTPError.MalformedRequest;
                self.set_host(host_string);

                const version_string = space_iter.next() orelse return HTTPError.MalformedRequest;
                _ = version_string;
                self.set_version(.@"HTTP/1.1");

                parsing_first_line = false;
            } else {
                var header_iter = std.mem.tokenizeScalar(u8, line, ':');
                const key = header_iter.next() orelse return HTTPError.MalformedRequest;
                const value = std.mem.trimLeft(u8, header_iter.rest(), &.{' '});
                try self.add_header(.{ .key = key, .value = value });
            }
        }
    }

    pub fn set_method(self: *Request, method: Method) void {
        self.method = method;
    }

    pub fn set_host(self: *Request, host: []const u8) void {
        self.host = host;
    }

    pub fn set_version(self: *Request, version: std.http.Version) void {
        self.version = version;
    }

    pub fn add_header(self: *Request, kv: KVPair) HTTPError!void {
        if (self.headers_idx < self.headers.len) {
            self.headers[self.headers_idx] = kv;
            self.headers_idx += 1;
        } else {
            return HTTPError.TooManyHeaders;
        }
    }

    pub fn clear_headers(self: *Request) void {
        self.headers_idx = 0;
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

    var request = Request.init(1024);
    try request.parse_headers(request_text[0..]);

    try testing.expectEqual(.GET, request.method);
    try testing.expectEqualStrings("/", request.host);
    try testing.expectEqual(.@"HTTP/1.1", request.version);
    try testing.expectEqualStrings("Host", request.headers[0].key);
    try testing.expectEqualStrings("localhost:9862", request.headers[0].value);
    try testing.expectEqualStrings("Connection", request.headers[1].key);
    try testing.expectEqualStrings("keep-alive", request.headers[1].value);
    try testing.expectEqualStrings("Accept", request.headers[2].key);
    try testing.expectEqualStrings("text/html", request.headers[2].value);
}
