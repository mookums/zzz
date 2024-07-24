const std = @import("std");
const assert = std.debug.assert;

const KVPair = @import("lib.zig").KVPair;
const Method = std.http.Method;

const RequestOptions = struct {
    request_max_size: usize = 4096,
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

    // This is for parsing it out of a buffer.
    pub fn parse(options: RequestOptions, buffer: []const u8) !Request {
        var request = Request.init(options);
        // Parse the Request here.
        const RequestLineParsing = enum {
            Method,
            Host,
            Version,
        };

        const HeaderParsing = enum {
            Name,
            Value,
        };

        const ParsingStages = enum {
            RequestLine,
            Headers,
        };

        const Parsing = union(ParsingStages) {
            RequestLine: RequestLineParsing,
            Headers: HeaderParsing,
        };

        var stage: Parsing = .{ .RequestLine = .Method };

        var start: usize = 0;
        var no_bytes_left = false;
        var key_value: KVPair = .{ .key = undefined, .value = undefined };

        parse: for (0..request.options.request_max_size) |i| {
            // Our byte is either valid or we set the no_bytes_left flag.
            const byte = blk: {
                if (i < buffer.len) {
                    break :blk buffer[i];
                } else {
                    no_bytes_left = true;
                    break :blk 0;
                }
            };

            switch (stage) {
                .RequestLine => |rl| {
                    if (std.ascii.isWhitespace(byte) or no_bytes_left) {
                        switch (rl) {
                            .Method => {
                                request.add_method(@enumFromInt(std.http.Method.parse(buffer[start..i])));
                                start = i;
                                stage = .{ .RequestLine = .Host };
                            },

                            .Host => {
                                request.add_host(buffer[start + 1 .. i]);
                                start = i;
                                stage = .{ .RequestLine = .Version };
                            },

                            .Version => {
                                // TODO: Parse This.
                                request.add_version(std.http.Version.@"HTTP/1.1");
                                start = i + 1;
                                stage = .{ .Headers = .Name };
                            },
                        }
                    }
                },

                .Headers => |h| {
                    // Possible Delimters...
                    if (byte == ':' or byte == '\n' or no_bytes_left) {
                        switch (h) {
                            .Name => {
                                if (byte == '\r' or byte == '\n') {
                                    continue;
                                }

                                if (byte != ':') {
                                    break :parse;
                                }

                                const key = std.mem.trimLeft(u8, buffer[start..i], &std.ascii.whitespace);
                                key_value.key = key;

                                // We want to skip the colon.
                                start = i + 1;
                                stage = .{ .Headers = .Value };
                            },

                            .Value => {
                                // Ignore colons in the Header Value.
                                if (byte == ':') {
                                    continue;
                                }

                                const value = std.mem.trimLeft(u8, buffer[start..i], &std.ascii.whitespace);
                                key_value.value = value;

                                try request.add_header(key_value);
                                start = i;
                                stage = .{ .Headers = .Name };
                            },
                        }
                    }
                },
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

    pub fn add_header(self: *Request, kv: KVPair) !void {
        // Ensure that these are proper headers.
        //assert(std.mem.indexOfScalar(u8, kv.key, ':') == null);
        //assert(std.mem.indexOfScalar(u8, kv.value, ':') == null);

        if (self.headers_idx < self.headers.len) {
            self.headers[self.headers_idx] = kv;
            self.headers_idx += 1;
        } else {
            return error.TooManyHeaders;
        }
    }

    pub fn add_body(self: *Request, body: []const u8) void {
        self.body = body;
    }
};
