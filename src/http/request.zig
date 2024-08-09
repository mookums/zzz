const std = @import("std");
const assert = std.debug.assert;

const KVPair = @import("lib.zig").KVPair;
const HTTPError = @import("lib.zig").HTTPError;
const Method = std.http.Method;

const RequestOptions = struct {
    request_max_size: u32 = 4096,
};

pub const Request = struct {
    options: RequestOptions,
    method: Method,
    host: []const u8,
    version: std.http.Version,
    headers: [32]KVPair = [_]KVPair{undefined} ** 32,
    body: []const u8,
    headers_idx: usize = 0,

    /// This is for constructing a Request.
    pub fn init(options: RequestOptions) Request {
        return Request{
            .options = options,
            .method = undefined,
            .host = undefined,
            .version = undefined,
            .body = undefined,
        };
    }

    pub fn parse(options: RequestOptions, bytes: []const u8) HTTPError!Request {
        var request = Request.init(options);

        var total_size: u32 = 0;
        var line_iter = std.mem.tokenizeAny(u8, bytes, "\r\n");

        var parsing_first_line = true;
        while (line_iter.next()) |line| {
            total_size += @intCast(line.len);

            if (total_size > options.request_max_size) {
                return HTTPError.PayloadTooLarge;
            }

            if (parsing_first_line) {
                var space_iter = std.mem.tokenizeScalar(u8, line, ' ');
                request.add_method(@enumFromInt(std.http.Method.parse(space_iter.next().?)));
                request.add_host(space_iter.next().?);
                request.add_version(.@"HTTP/1.1");
                parsing_first_line = false;
            } else {
                var header_iter = std.mem.tokenizeScalar(u8, line, ':');
                const key = header_iter.next().?;
                const value = std.mem.trimLeft(u8, header_iter.rest(), &.{' '});
                try request.add_header(.{ .key = key, .value = value });
            }
        }

        return request;
    }

    pub fn add_method(self: *Request, method: Method) void {
        self.method = method;
    }

    pub fn add_host(self: *Request, host: []const u8) void {
        self.host = host;
    }

    pub fn add_version(self: *Request, version: std.http.Version) void {
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

    pub fn add_body(self: *Request, body: []const u8) void {
        self.body = body;
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

    const request = try Request.parse(.{}, request_text[0..]);

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
