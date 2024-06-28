const std = @import("std");
const Method = std.http.Method;

const HeaderError = error{ InvalidMethod, InvalidVersion, UnsupportedConversion, Generic };

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
        _ => HeaderError.UnsupportedConversion,
    };
}

pub fn to_zzz_http_version(ver: std.http.Version) Version {
    return switch (ver) {
        .@"HTTP/1.0" => Version.HTTP1,
        .@"HTTP/1.1" => Version.HTTP1D1,
    };
}

fn parse_method(str: []u8) HeaderError!Method {
    var i: usize = 0;
    for (str) |c| {
        str[i] = std.ascii.toUpper(c);
        i += 1;
    }

    const upper = std.mem.trim(u8, str, &std.ascii.whitespace);

    // Need a safer alternative at some point.
    return @enumFromInt(Method.parse(upper));
}

fn parse_http_version(str: []u8) HeaderError!Version {
    // ensure it is uppercase.
    var i: usize = 0;
    for (str) |c| {
        str[i] = std.ascii.toUpper(c);
        i += 1;
    }

    // trim all whitespace.
    const upper = std.mem.trim(u8, str, &std.ascii.whitespace);

    if (std.mem.eql(u8, upper, "HTTP/1.0")) {
        return Version.HTTP1;
    } else if (std.mem.eql(u8, upper, "HTTP/1.1")) {
        return Version.HTTP1D1;
    } else if (std.mem.eql(u8, upper, "HTTP/2")) {
        return Version.HTTP2;
    } else if (std.mem.eql(u8, upper, "HTTP/3")) {
        return Version.HTTP3;
    } else {
        return HeaderError.InvalidVersion;
    }
}

pub const Header = struct {
    allocator: std.mem.Allocator,
    method: Method = undefined,
    host: std.ArrayList(u8) = undefined,
    version: Version = undefined,

    pub fn init(allocator: std.mem.Allocator) Header {
        return Header{
            .allocator = allocator,
            .host = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: Header) void {
        self.host.deinit();
    }

    pub fn parse(self: *Header, msg: []u8) !void {
        const HeaderParsingStage = enum {
            Method,
            Host,
            Version,
        };

        // Parse out the first Header line.
        var stage: HeaderParsingStage = .Method;
        var start: usize = 0;
        var end: usize = 0;
        parse: for (msg) |c| {
            // Split on spaces or if we are at the end.
            if ((c == ' ') or (end == msg.len - 1)) {
                end += 1;
                switch (stage) {
                    .Method => {
                        self.method = try parse_method(msg[start..end]);
                        std.debug.print("Header Request Type: {s}\n", .{@tagName(self.method)});
                        start = end;
                        stage = .Host;
                    },

                    .Host => {
                        try self.host.appendSlice(msg[start..end]);
                        std.debug.print("Header Host: {s}\n", .{self.host.items});
                        start = end;
                        stage = .Version;
                    },

                    .Version => {
                        self.version = try parse_http_version(msg[start..end]);
                        std.debug.print("Header Version: {s}\n", .{@tagName(self.version)});
                        start = end;
                        break :parse;
                    },
                }
            } else {
                end += 1;
            }
        }
    }
};
