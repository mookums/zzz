const std = @import("std");
const assert = std.debug.assert;

pub const Status = enum(u16) {
    Continue = 100,
    @"Switching Protocols" = 101,
    Processing = 102,
    @"Early Hints" = 103,
    OK = 200,
    Created = 201,
    Accepted = 202,
    @"Non-Authoritative Informaton" = 203,
    @"No Content" = 204,
    @"Reset Content" = 205,
    @"Multi-Status" = 207,
    @"Already Reported" = 208,
    @"IM Used" = 226,
    @"Multiple Choices" = 300,
    @"Moved Permanently" = 301,
    Found = 302,
    @"See Other" = 303,
    @"Not Modified" = 304,
    @"Temporary Redirect" = 307,
    @"Permanent Redirect" = 308,
    @"Bad Request" = 400,
    Unauthroized = 401,
    @"Payment Required" = 402,
    Forbidden = 403,
    @"Not Found" = 404,
    @"Method Not Allowed" = 405,
    @"Not Acceptable" = 406,
    @"Proxy Authentication Required" = 407,
    @"Request Timeout" = 408,
    Conflict = 409,
    Gone = 410,
    @"Length Required" = 411,
    @"Precondition Failed" = 412,
    @"Payload Too Large" = 413,
    @"URI Too Long" = 414,
    @"Unsupported Media Type" = 415,
    @"Range Not Satisfiable" = 416,
    @"Expectation Failed" = 417,
    @"I'm a Teapot" = 418,
    @"Misdirected Request" = 421,
    @"Unprocessable Content" = 422,
    Locked = 423,
    @"Failed Dependency" = 424,
    @"Too Early" = 425,
    @"Upgrade Required" = 426,
    @"Precondition Required" = 428,
    @"Too Many Requests" = 429,
    @"Request Headers Fields Too Large" = 431,
    @"Unavailable for Legal Reasons" = 451,
    @"Internal Server Error" = 500,
    @"Not Implemented" = 501,
    @"Bad Gateway" = 502,
    @"Service Unavailable" = 503,
    @"Gateway Timeout" = 504,
    @"HTTP Version Not Supported" = 505,
    @"Variant Also Negotiates" = 506,
    @"Insufficient Storage" = 507,
    @"Loop Detected" = 508,
    @"Not Extended" = 510,
    @"Network Authentication Required" = 511,
};

const KVPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Response = struct {
    const Self = @This();
    status: Status,
    headers: [32]?KVPair = [_]?KVPair{null} ** 32,
    headers_idx: usize = 0,

    pub fn init(status: Status) Self {
        return Self{ .status = status };
    }

    pub fn add_header(self: *Self, kv: KVPair) void {
        // Ensure that these are proper headers.
        assert(std.mem.indexOfScalar(u8, kv.key, ':') == null);
        assert(std.mem.indexOfScalar(u8, kv.value, ':') == null);

        if (self.headers_idx < 32) {
            self.headers[self.headers_idx] = kv;
            self.headers_idx += 1;
        } else {
            @panic("Too many headers!");
        }
    }

    /// Writes this response to the given Writer. This is assumed to be a BufferedWriter
    /// for the TCP stream.
    pub fn respond(self: *Self, body: []const u8, writer: anytype) !void {
        // Status Line
        try writer.writeAll("HTTP/1.1 ");
        try std.fmt.formatInt(@intFromEnum(self.status), 10, .lower, .{}, writer);
        try writer.writeAll(" ");
        try writer.writeAll(@tagName(self.status));
        try writer.writeAll("\n");

        // Headers
        for (self.headers) |header| {
            if (header) |h| {
                try writer.writeAll(h.key);
                try writer.writeAll(": ");
                try writer.writeAll(h.value);
                try writer.writeAll("\n");
            }
        }

        // Body
        try writer.writeAll("\r\n");
        try writer.writeAll(body);
    }
};
