const std = @import("std");
const assert = std.debug.assert;
const Method = std.http.Method;

const RequestLineError = error{ InvalidMethod, InvalidVersion, UnsupportedConversion, Generic };

const Version = enum {
    HTTP1,
    HTTP1D1,
    HTTP2,
    HTTP3,
};

pub fn to_std_http_version(ours: Version) Version!std.http.Version {
    return switch (ours) {
        .HTTP1 => std.http.Version.@"HTTP/1.0",
        .HTTP1D1 => std.http.Version.@"HTTP/1.1",
        _ => RequestLineError.UnsupportedConversion,
    };
}

pub fn to_zzz_http_version(ver: std.http.Version) Version {
    return switch (ver) {
        .@"HTTP/1.0" => Version.HTTP1,
        .@"HTTP/1.1" => Version.HTTP1D1,
    };
}

fn parse_method(str: []const u8) RequestLineError!Method {
    // Longest HTTP Method is "CONNECT" or "OPTIONS" which are both 7 characters.
    // TODO: make this also a setting.
    const HTTP_METHOD_MAX_LENGTH = 16;

    if (str.len > HTTP_METHOD_MAX_LENGTH) {
        std.debug.print("INVALID LENGTH of {d} with contents: {s}\n", .{ str.len, str });
        return RequestLineError.InvalidMethod;
    }

    var str_buffer: [HTTP_METHOD_MAX_LENGTH]u8 = [_]u8{' '} ** HTTP_METHOD_MAX_LENGTH;
    var str_copy = &str_buffer;

    var i: usize = 0;
    for (str) |c| {
        if (std.ascii.isWhitespace(c)) {
            break;
        }

        str_copy[i] = std.ascii.toUpper(c);
        i += 1;
    }
    const trimmed = str_copy[0..i];

    // Eventually, we can probably make this faster by only looking at the first two bytes of the method.
    // Need a safer alternative at some point.
    return @enumFromInt(Method.parse(trimmed));
}

fn parse_http_version(str: []const u8) RequestLineError!Version {
    // Longest HTTP Version is "HTTP/1.1" which is 8 characters.
    // TODO: make this also a setting. This is too strict.
    const HTTP_VERSION_MAX_LENGTH = 16;

    var str_buffer: [HTTP_VERSION_MAX_LENGTH]u8 = [_]u8{' '} ** HTTP_VERSION_MAX_LENGTH;
    var str_copy = &str_buffer;

    var i: usize = 0;
    for (str) |c| {
        if (std.ascii.isWhitespace(c)) {
            break;
        }

        str_copy[i] = std.ascii.toUpper(c);
        i += 1;
    }

    // HTTP Versions are the same until index 5.
    const trimmed = str_copy[5..i];

    if (std.mem.eql(u8, trimmed, "1.0")) {
        return Version.HTTP1;
    } else if (std.mem.eql(u8, trimmed, "1.1")) {
        return Version.HTTP1D1;
        // We technically don't support anything under this.
    } else if (std.mem.eql(u8, trimmed, "2")) {
        return Version.HTTP2;
    } else if (std.mem.eql(u8, trimmed, "3")) {
        return Version.HTTP3;
    } else {
        return RequestLineError.InvalidVersion;
    }
}

pub const RequestLine = struct {
    inner: []const u8,
    method: Method = undefined,
    // Eventually make this a comptime option?
    // Def make it a comptime option.
    host: [1024]u8 = undefined,
    version: Version = undefined,

    pub fn init(msg: []const u8) RequestLine {
        return RequestLine{
            .inner = msg,
            .host = [1]u8{' '} ** 1024,
        };
    }

    pub inline fn getMethod(self: RequestLine) Method {
        return self.method;
    }

    pub inline fn getHost(self: RequestLine) []const u8 {
        return std.mem.trim(u8, &self.host, &std.ascii.whitespace);
    }

    pub inline fn getVersion(self: RequestLine) Version {
        return self.version;
    }

    pub fn parse(self: *RequestLine) !void {
        const RequestLineParsingStage = enum {
            Method,
            Host,
            Version,
            Done,
        };
        var stage: RequestLineParsingStage = .Method;

        // Who doesn't love a good iterator? <3
        var split_iter = std.mem.splitScalar(u8, self.inner, ' ');
        parse: while (split_iter.next()) |chunk| {
            switch (stage) {
                .Method => {
                    self.method = try parse_method(chunk);
                    std.debug.print("Request Method: {s}\n", .{@tagName(self.method)});
                    stage = .Host;
                },

                .Host => {
                    std.mem.copyForwards(u8, &self.host, chunk);
                    std.debug.print("Request Host: {s}\n", .{self.getHost()});
                    stage = .Version;
                },

                .Version => {
                    self.version = try parse_http_version(chunk);
                    std.debug.print("Request Version: {s}\n", .{@tagName(self.version)});
                    stage = .Done;
                    break :parse;
                },
                else => {
                    // Throw some error here about malformed request.
                },
            }
        }

        if (stage != .Done) {
            // Throw some error here about malformed request.
        }
    }
};

// RequestLine Parsing Test!
const testing = std.testing;
test "parse simple GET" {
    const example = "GET http://localhost.com HTTP/1.1";
    var request_line = RequestLine.init(example);
    try request_line.parse();

    try std.testing.expectEqual(Method.GET, request_line.getMethod());
    try std.testing.expectEqualStrings("http://localhost.com", request_line.getHost());
    try std.testing.expectEqual(Version.HTTP1D1, request_line.getVersion());
}
