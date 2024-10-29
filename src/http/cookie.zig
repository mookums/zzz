const std = @import("std");

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    // TODO: Use timstamp type instead?
    expires: ?[]const u8 = null,
    max_age: ?i64 = null,
    secure: bool = false,
    http_only: bool = false,
    same_site: ?SameSite = null,

    pub const SameSite = enum(u2) {
        Strict,
        Lax,
        None,

        pub fn toString(self: SameSite) []const u8 {
            return switch (self) {
                .Strict => "Strict",
                .Lax => "Lax",
                .None => "None",
            };
        }
    };
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
    pub fn parseRequestCookies(self: *CookieMap, cookie_header: []const u8) !void {
        self.clear();

        var pairs = std.mem.splitSequence(u8, cookie_header, "; ");
        while (pairs.next()) |pair| {
            var kv = std.mem.splitScalar(u8, pair, '=');
            const key = kv.next() orelse continue;
            const value = kv.next() orelse continue;

            if (kv.next() != null) {
                continue;
            }

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

    pub fn formatSetCookie(cookie: Cookie, allocator: std.mem.Allocator) ![]const u8 {
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();

        try list.writer().print("{s}={s}", .{ cookie.name, cookie.value });

        if (cookie.domain) |domain| {
            try list.writer().print("; Domain={s}", .{domain});
        }
        if (cookie.path) |path| {
            try list.writer().print("; Path={s}", .{path});
        }
        if (cookie.expires) |exp| {
            try list.writer().print("; Expires={s}", .{exp});
        }
        if (cookie.max_age) |age| {
            try list.writer().print("; Max-Age={d}", .{age});
        }
        if (cookie.same_site) |same_site| {
            try list.writer().print("; SameSite={s}", .{same_site.toString()});
        }
        if (cookie.secure) {
            try list.writer().writeAll("; Secure");
        }
        if (cookie.http_only) {
            try list.writer().writeAll("; HttpOnly");
        }

        return list.toOwnedSlice();
    }
};

const testing = std.testing;

test "Request Cookie Parsing" {
    var cookie_map = CookieMap.init(testing.allocator);
    defer cookie_map.deinit();

    try cookie_map.parseRequestCookies("sessionId=abc123; theme=dark");
    try testing.expectEqualStrings("abc123", cookie_map.get("sessionId").?);
    try testing.expectEqualStrings("dark", cookie_map.get("theme").?);
}

test "Response Cookie Formatting" {
    const cookie = Cookie{
        .name = "session",
        .value = "abc123",
        .path = "/",
        .domain = "example.com",
        .secure = true,
        .http_only = true,
        .same_site = .Strict,
        .max_age = 3600,
    };

    const formatted = try CookieMap.formatSetCookie(cookie, testing.allocator);
    defer testing.allocator.free(formatted);

    try testing.expectEqualStrings(
        "session=abc123; Domain=example.com; Path=/; Max-Age=3600; SameSite=Strict; Secure; HttpOnly",
        formatted,
    );
}
