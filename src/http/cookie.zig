const std = @import("std");
const Date = @import("date.zig").Date;

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    expires: ?Date = null,
    max_age: ?u32 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,

    pub fn init(name: []const u8, value: []const u8) Cookie {
        return .{
            .name = name,
            .value = value,
        };
    }

    pub const SameSite = enum {
        strict,
        lax,
        none,

        pub fn to_string(self: SameSite) []const u8 {
            return switch (self) {
                .strict => "Strict",
                .lax => "Lax",
                .none => "None",
            };
        }
    };

    pub fn to_string_buf(self: Cookie, buf: []u8) ![]const u8 {
        var list = std.ArrayListUnmanaged(u8).initBuffer(buf);
        const writer = list.fixedWriter();

        try writer.print("{s}={s}", .{ self.name, self.value });
        if (self.domain) |domain| try writer.print("; Domain={s}", .{domain});
        if (self.path) |path| try writer.print("; Path={s}", .{path});
        if (self.expires) |exp| {
            try writer.writeAll("; Expires=");
            try exp.to_http_date().into_writer(writer);
        }
        if (self.max_age) |age| try writer.print("; Max-Age={d}", .{age});
        if (self.same_site) |same_site| try writer.print(
            "; SameSite={s}",
            .{same_site.to_string()},
        );
        if (self.secure) try writer.writeAll("; Secure");
        if (self.http_only) try writer.writeAll("; HttpOnly");

        return list.items;
    }

    pub fn to_string_alloc(self: Cookie, allocator: std.mem.Allocator) ![]const u8 {
        var list = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 128);
        errdefer list.deinit(allocator);
        const writer = list.writer(allocator);

        try writer.print("{s}={s}", .{ self.name, self.value });
        if (self.domain) |domain| try writer.print("; Domain={s}", .{domain});
        if (self.path) |path| try writer.print("; Path={s}", .{path});
        if (self.expires) |exp| {
            try writer.writeAll("; Expires=");
            try exp.to_http_date().into_writer(writer);
        }
        if (self.max_age) |age| try writer.print("; Max-Age={d}", .{age});
        if (self.same_site) |same_site| try writer.print(
            "; SameSite={s}",
            .{same_site.to_string()},
        );
        if (self.secure) try writer.writeAll("; Secure");
        if (self.http_only) try writer.writeAll("; HttpOnly");

        return list.toOwnedSlice(allocator);
    }
};

pub const CookieMap = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) CookieMap {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *CookieMap) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn clear(self: *CookieMap) void {
        var iter = self.map.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.clearRetainingCapacity();
    }

    pub fn get(self: CookieMap, name: []const u8) ?[]const u8 {
        return self.map.get(name);
    }

    pub fn count(self: CookieMap) usize {
        return self.map.count();
    }

    pub fn iterator(self: *const CookieMap) std.StringHashMap([]const u8).Iterator {
        return self.map.iterator();
    }

    // For parsing request cookies (simple key=value pairs)
    pub fn parse_from_header(self: *CookieMap, cookie_header: []const u8) !void {
        self.clear();

        var pairs = std.mem.splitSequence(u8, cookie_header, "; ");
        while (pairs.next()) |pair| {
            var kv = std.mem.splitScalar(u8, pair, '=');
            const key = kv.next() orelse continue;
            const value = kv.next() orelse continue;
            if (kv.next() != null) continue;

            const key_dup = try self.allocator.dupe(u8, key);
            errdefer self.allocator.free(key_dup);
            const value_dup = try self.allocator.dupe(u8, value);
            errdefer self.allocator.free(value_dup);

            if (try self.map.fetchPut(key_dup, value_dup)) |existing| {
                self.allocator.free(existing.key);
                self.allocator.free(existing.value);
            }
        }
    }
};

const testing = std.testing;

test "Cookie: Header Parsing" {
    var cookie_map = CookieMap.init(testing.allocator);
    defer cookie_map.deinit();

    try cookie_map.parse_from_header("sessionId=abc123; java=slop");
    try testing.expectEqualStrings("abc123", cookie_map.get("sessionId").?);
    try testing.expectEqualStrings("slop", cookie_map.get("java").?);
}

test "Cookie: Response Formatting" {
    const cookie = Cookie{
        .name = "session",
        .value = "abc123",
        .path = "/",
        .domain = "example.com",
        .secure = true,
        .http_only = true,
        .same_site = .strict,
        .max_age = 3600,
    };

    const formatted = try cookie.to_string_alloc(testing.allocator);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings(
        "session=abc123; Domain=example.com; Path=/; Max-Age=3600; SameSite=Strict; Secure; HttpOnly",
        formatted,
    );
}
