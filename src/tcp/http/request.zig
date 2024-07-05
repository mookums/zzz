const std = @import("std");
const assert = std.debug.assert;

const KVPair = @import("lib.zig").KVPair;
const Method = std.http.Method;

const RequestOptions = struct {
    headers_size: usize = 32,
};

pub fn Request(comptime options: RequestOptions) type {
    return struct {
        const Self = @This();
        method: Method,
        host: []const u8,
        version: std.http.Version,
        headers: [options.headers_size]KVPair = [_]KVPair{undefined} ** options.headers_size,
        body: []const u8,
        headers_idx: usize = 0,

        pub fn init() Self {
            return Self{
                .method = undefined,
                .host = undefined,
                .version = undefined,
                .body = undefined,
            };
        }

        pub fn add_method(self: *Self, method: Method) void {
            self.method = method;
        }

        pub fn add_host(self: *Self, host: []const u8) void {
            self.host = host;
        }

        pub fn add_version(self: *Self, version: std.http.Version) void {
            self.version = version;
        }

        pub fn add_header(self: *Self, kv: KVPair) void {
            // Ensure that these are proper headers.
            //assert(std.mem.indexOfScalar(u8, kv.key, ':') == null);
            //assert(std.mem.indexOfScalar(u8, kv.value, ':') == null);

            if (self.headers_idx < options.headers_size) {
                self.headers[self.headers_idx] = kv;
                self.headers_idx += 1;
            } else {
                @panic("Too many headers!");
            }
        }

        pub fn add_body(self: *Self, body: []const u8) void {
            self.body = body;
        }
    };
}
