const std = @import("std");
const assert = std.debug.assert;

const Headers = @import("lib.zig").Headers;
const HTTPError = @import("lib.zig").HTTPError;
const Method = @import("lib.zig").Method;

const RequestOptions = struct {
    size_request_max: u32,
    num_header_max: u32,
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    size_request_max: u32,
    method: Method,
    host: []const u8,
    version: std.http.Version,
    headers: Headers,
    body: []const u8,

    /// This is for constructing a Request.
    pub fn init(allocator: std.mem.Allocator, options: RequestOptions) !Request {
        return Request{
            .allocator = allocator,
            .headers = try Headers.init(allocator, options.num_header_max),
            .size_request_max = options.size_request_max,
            .method = undefined,
            .host = undefined,
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
                try self.headers.add(key, value);
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

    var request = try Request.init(testing.allocator, .{ .num_header_max = 32, .size_request_max = 1024 });
    defer request.deinit();

    try request.parse_headers(request_text[0..]);

    try testing.expectEqual(.GET, request.method);
    try testing.expectEqualStrings("/", request.host);
    try testing.expectEqual(.@"HTTP/1.1", request.version);

    try testing.expectEqualStrings("localhost:9862", request.headers.get("Host").?);
    try testing.expectEqualStrings("keep-alive", request.headers.get("Connection").?);
    try testing.expectEqualStrings("text/html", request.headers.get("Accept").?);
}
