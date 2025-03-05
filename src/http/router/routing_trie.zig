const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/routing_trie");

const Layer = @import("middleware.zig").Layer;
const Route = @import("route.zig").Route;

const Respond = @import("../response.zig").Respond;
const Context = @import("../lib.zig").Context;

const HandlerWithData = @import("route.zig").HandlerWithData;
const MiddlewareWithData = @import("middleware.zig").MiddlewareWithData;
const AnyCaseStringMap = @import("../../core/any_case_string_map.zig").AnyCaseStringMap;

const decode_alloc = @import("../form.zig").decode_alloc;

fn TokenHashMap(comptime V: type) type {
    return std.HashMap(Token, V, struct {
        pub fn hash(self: @This(), input: Token) u64 {
            _ = self;

            const bytes = blk: {
                switch (input) {
                    .fragment => |inner| break :blk inner,
                    .match => |inner| break :blk @tagName(inner),
                }
            };

            return std.hash.Wyhash.hash(0, bytes);
        }

        pub fn eql(self: @This(), first: Token, second: Token) bool {
            _ = self;

            const result = blk: {
                switch (first) {
                    .fragment => |f_inner| {
                        switch (second) {
                            .fragment => |s_inner| break :blk std.mem.eql(u8, f_inner, s_inner),
                            else => break :blk false,
                        }
                    },
                    .match => |f_inner| {
                        switch (second) {
                            .match => |s_inner| break :blk f_inner == s_inner,
                            else => break :blk false,
                        }
                    },
                }
            };

            return result;
        }
    }, 80);
}

const TokenEnum = enum(u8) {
    fragment = 0,
    match = 1,
};

pub const TokenMatch = enum {
    unsigned,
    signed,
    float,
    string,
    remaining,

    pub fn as_type(match: TokenMatch) type {
        switch (match) {
            .unsigned => return u64,
            .signed => return i64,
            .float => return f64,
            .string => return []const u8,
            .remaining => return []const u8,
        }
    }
};

pub const Token = union(TokenEnum) {
    fragment: []const u8,
    match: TokenMatch,

    pub fn parse_chunk(chunk: []const u8) Token {
        if (std.mem.startsWith(u8, chunk, "%")) {
            // Needs to be only % and an identifier.
            assert(chunk.len == 2);

            switch (chunk[1]) {
                'i', 'd' => return .{ .match = .signed },
                'u' => return .{ .match = .unsigned },
                'f' => return .{ .match = .float },
                's' => return .{ .match = .string },
                'r' => return .{ .match = .remaining },
                else => @panic("Unsupported Match!"),
            }
        } else {
            return .{ .fragment = chunk };
        }
    }
};

pub const Query = struct {
    key: []const u8,
    value: []const u8,
};

pub const Capture = union(TokenMatch) {
    unsigned: TokenMatch.unsigned.as_type(),
    signed: TokenMatch.signed.as_type(),
    float: TokenMatch.float.as_type(),
    string: TokenMatch.string.as_type(),
    remaining: TokenMatch.remaining.as_type(),
};

/// Structure of a matched route.
pub const Bundle = struct {
    route: Route,
    captures: []Capture,
    queries: *AnyCaseStringMap,
    duped: []const []const u8,
};

// This RoutingTrie is deleteless. It only can create new routes or update existing ones.
pub const RoutingTrie = struct {
    const Self = @This();

    /// Structure of a node of the trie.
    pub const Node = struct {
        token: Token,
        route: ?Route = null,
        children: TokenHashMap(Node),

        /// Initialize a new empty node.
        pub fn init(allocator: std.mem.Allocator, token: Token, route: ?Route) Node {
            return .{
                .token = token,
                .route = route,
                .children = TokenHashMap(Node).init(allocator),
            };
        }

        pub fn deinit(self: *Node) void {
            var iter = self.children.valueIterator();

            while (iter.next()) |node| {
                node.deinit();
            }

            self.children.deinit();
        }
    };

    root: Node,
    middlewares: std.ArrayListUnmanaged(MiddlewareWithData),

    /// Initialize the routing tree with the given routes.
    pub fn init(allocator: std.mem.Allocator, layers: []const Layer) !Self {
        var self: Self = .{
            .root = Node.init(allocator, .{ .fragment = "" }, null),
            .middlewares = try std.ArrayListUnmanaged(MiddlewareWithData).initCapacity(allocator, 0),
        };

        for (layers) |layer| {
            switch (layer) {
                .route => |route| {
                    var current = &self.root;
                    var iter = std.mem.tokenizeScalar(u8, route.path, '/');

                    while (iter.next()) |chunk| {
                        const token: Token = Token.parse_chunk(chunk);
                        if (current.children.getPtr(token)) |child| {
                            current = child;
                        } else {
                            try current.children.put(token, Node.init(allocator, token, null));
                            current = current.children.getPtr(token).?;
                        }
                    }

                    const r: *Route = if (current.route) |*inner| inner else blk: {
                        current.route = route;
                        break :blk &current.route.?;
                    };

                    for (route.handlers, 0..) |handler, i| if (handler) |h| {
                        r.handlers[i] = HandlerWithData{
                            .handler = h.handler,
                            .middlewares = self.middlewares.items,
                            .data = h.data,
                        };
                    };
                },
                .middleware => |mw| try self.middlewares.append(allocator, mw),
            }
        }

        return self;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.root.deinit();
        self.middlewares.deinit(allocator);
    }

    pub fn get_bundle(
        self: Self,
        allocator: std.mem.Allocator,
        path: []const u8,
        captures: []Capture,
        queries: *AnyCaseStringMap,
    ) !?Bundle {
        var capture_idx: usize = 0;
        const query_pos = std.mem.indexOfScalar(u8, path, '?');
        var iter = std.mem.tokenizeScalar(u8, path[0..(query_pos orelse path.len)], '/');

        var current = self.root;

        slash_loop: while (iter.next()) |chunk| {
            var child_iter = current.children.iterator();
            child_loop: while (child_iter.next()) |entry| {
                const token = entry.key_ptr.*;
                const child = entry.value_ptr.*;

                switch (token) {
                    .fragment => |inner| if (std.mem.eql(u8, inner, chunk)) {
                        current = child;
                        continue :slash_loop;
                    },
                    .match => |kind| {
                        switch (kind) {
                            .signed => if (std.fmt.parseInt(i64, chunk, 10)) |value| {
                                captures[capture_idx] = Capture{ .signed = value };
                            } else |_| continue :child_loop,
                            .unsigned => if (std.fmt.parseInt(u64, chunk, 10)) |value| {
                                captures[capture_idx] = Capture{ .unsigned = value };
                            } else |_| continue :child_loop,
                            // Float types MUST have a '.' to differentiate them.
                            .float => if (std.mem.indexOfScalar(u8, chunk, '.')) |_| {
                                if (std.fmt.parseFloat(f64, chunk)) |value| {
                                    captures[capture_idx] = Capture{ .float = value };
                                } else |_| continue :child_loop;
                            } else continue :child_loop,
                            .string => captures[capture_idx] = Capture{ .string = chunk },
                            .remaining => {
                                const rest = iter.buffer[(iter.index - chunk.len)..];
                                captures[capture_idx] = Capture{ .remaining = rest };

                                current = child;
                                capture_idx += 1;

                                break :slash_loop;
                            },
                        }

                        current = child;
                        capture_idx += 1;
                        if (capture_idx > captures.len) return error.TooManyCaptures;
                        continue :slash_loop;
                    },
                }
            }

            // If we failed to match, this is an invalid route.
            return null;
        }

        var duped = try std.ArrayListUnmanaged([]const u8).initCapacity(allocator, 0);
        defer duped.deinit(allocator);
        errdefer for (duped.items) |d| allocator.free(d);

        if (query_pos) |pos| {
            if (path.len > pos + 1) {
                var query_iter = std.mem.tokenizeScalar(u8, path[pos + 1 ..], '&');

                while (query_iter.next()) |chunk| {
                    const field_idx = std.mem.indexOfScalar(u8, chunk, '=') orelse return error.MissingValue;
                    if (chunk.len < field_idx + 2) return error.MissingValue;

                    const key = chunk[0..field_idx];
                    const value = chunk[(field_idx + 1)..];

                    if (std.mem.indexOfScalar(u8, value, '=') != null) return error.MalformedPair;

                    const decoded_key = try decode_alloc(allocator, key);
                    try duped.append(allocator, decoded_key);

                    const decoded_value = try decode_alloc(allocator, value);
                    try duped.append(allocator, decoded_value);

                    // Later values will clobber earlier ones.
                    try queries.put(decoded_key, decoded_value);
                }
            }
        }

        return Bundle{
            .route = current.route orelse return null,
            .captures = captures[0..capture_idx],
            .queries = queries,
            .duped = try duped.toOwnedSlice(allocator),
        };
    }
};

const testing = std.testing;

test "Chunk Parsing (Fragment)" {
    const chunk = "thisIsAFragment";
    const token: Token = Token.parse_chunk(chunk);

    switch (token) {
        .fragment => |inner| try testing.expectEqualStrings(chunk, inner),
        .match => return error.IncorrectTokenParsing,
    }
}

test "Chunk Parsing (Match)" {
    const chunks: [5][]const u8 = .{
        "%i",
        "%d",
        "%u",
        "%f",
        "%s",
    };

    const matches = [_]TokenMatch{
        TokenMatch.signed,
        TokenMatch.signed,
        TokenMatch.unsigned,
        TokenMatch.float,
        TokenMatch.string,
    };

    for (chunks, matches) |chunk, match| {
        const token: Token = Token.parse_chunk(chunk);

        switch (token) {
            .fragment => return error.IncorrectTokenParsing,
            .match => |inner| try testing.expectEqual(match, inner),
        }
    }
}

test "Path Parsing (Mixed)" {
    const path = "/item/%i/description";

    const parsed: [3]Token = .{
        .{ .fragment = "item" },
        .{ .match = .signed },
        .{ .fragment = "description" },
    };

    var iter = std.mem.tokenizeScalar(u8, path, '/');

    for (parsed) |expected| {
        const token = Token.parse_chunk(iter.next().?);
        switch (token) {
            .fragment => |inner| try testing.expectEqualStrings(expected.fragment, inner),
            .match => |inner| try testing.expectEqual(expected.match, inner),
        }
    }
}

test "Constructing Routing from Path" {
    var s = try RoutingTrie.init(testing.allocator, &.{
        Route.init("/item").layer(),
        Route.init("/item/%i/description").layer(),
        Route.init("/item/%i/hello").layer(),
        Route.init("/item/%f/price_float").layer(),
        Route.init("/item/name/%s").layer(),
        Route.init("/item/list").layer(),
    });
    defer s.deinit(testing.allocator);

    try testing.expectEqual(1, s.root.children.count());
}

test "Routing with Paths" {
    var s = try RoutingTrie.init(testing.allocator, &.{
        Route.init("/item").layer(),
        Route.init("/item/%i/description").layer(),
        Route.init("/item/%i/hello").layer(),
        Route.init("/item/%f/price_float").layer(),
        Route.init("/item/name/%s").layer(),
        Route.init("/item/list").layer(),
    });
    defer s.deinit(testing.allocator);

    var q = AnyCaseStringMap.init(testing.allocator);
    defer q.deinit();

    var captures: [8]Capture = [_]Capture{undefined} ** 8;

    try testing.expectEqual(null, try s.get_bundle(testing.allocator, "/item/name", captures[0..], &q));

    {
        const captured = (try s.get_bundle(testing.allocator, "/item/name/HELLO", captures[0..], &q)).?;

        try testing.expectEqual(Route.init("/item/name/%s"), captured.route);
        try testing.expectEqualStrings("HELLO", captured.captures[0].string);
    }

    {
        const captured = (try s.get_bundle(testing.allocator, "/item/2112.22121/price_float", captures[0..], &q)).?;

        try testing.expectEqual(Route.init("/item/%f/price_float"), captured.route);
        try testing.expectEqual(2112.22121, captured.captures[0].float);
    }
}

test "Routing with Remaining" {
    var s = try RoutingTrie.init(testing.allocator, &.{
        Route.init("/item").layer(),
        Route.init("/item/%f/price_float").layer(),
        Route.init("/item/name/%r").layer(),
        Route.init("/item/%i/price/%f").layer(),
    });
    defer s.deinit(testing.allocator);

    var q = AnyCaseStringMap.init(testing.allocator);
    defer q.deinit();

    var captures: [8]Capture = [_]Capture{undefined} ** 8;

    try testing.expectEqual(null, try s.get_bundle(testing.allocator, "/item/name", captures[0..], &q));

    {
        const captured = (try s.get_bundle(testing.allocator, "/item/name/HELLO", captures[0..], &q)).?;
        try testing.expectEqual(Route.init("/item/name/%r"), captured.route);
        try testing.expectEqualStrings("HELLO", captured.captures[0].remaining);
    }
    {
        const captured = (try s.get_bundle(
            testing.allocator,
            "/item/name/THIS/IS/A/FILE/SYSTEM/PATH.html",
            captures[0..],
            &q,
        )).?;
        try testing.expectEqual(Route.init("/item/name/%r"), captured.route);
        try testing.expectEqualStrings("THIS/IS/A/FILE/SYSTEM/PATH.html", captured.captures[0].remaining);
    }

    {
        const captured = (try s.get_bundle(
            testing.allocator,
            "/item/2112.22121/price_float",
            captures[0..],
            &q,
        )).?;
        try testing.expectEqual(Route.init("/item/%f/price_float"), captured.route);
        try testing.expectEqual(2112.22121, captured.captures[0].float);
    }

    {
        const captured = (try s.get_bundle(
            testing.allocator,
            "/item/100/price/283.21",
            captures[0..],
            &q,
        )).?;
        try testing.expectEqual(Route.init("/item/%i/price/%f"), captured.route);
        try testing.expectEqual(100, captured.captures[0].signed);
        try testing.expectEqual(283.21, captured.captures[1].float);
    }
}

test "Routing with Queries" {
    var s = try RoutingTrie.init(testing.allocator, &.{
        Route.init("/item").layer(),
        Route.init("/item/%f/price_float").layer(),
        Route.init("/item/name/%r").layer(),
        Route.init("/item/%i/price/%f").layer(),
    });
    defer s.deinit(testing.allocator);

    var q = AnyCaseStringMap.init(testing.allocator);
    defer q.deinit();

    var captures: [8]Capture = [_]Capture{undefined} ** 8;

    try testing.expectEqual(null, try s.get_bundle(
        testing.allocator,
        "/item/name",
        captures[0..],
        &q,
    ));

    {
        q.clearRetainingCapacity();
        const captured = (try s.get_bundle(
            testing.allocator,
            "/item/name/HELLO?name=muki&food=waffle",
            captures[0..],
            &q,
        )).?;
        defer testing.allocator.free(captured.duped);
        defer for (captured.duped) |dupe| testing.allocator.free(dupe);
        try testing.expectEqual(Route.init("/item/name/%r"), captured.route);
        try testing.expectEqualStrings("HELLO", captured.captures[0].remaining);
        try testing.expectEqual(2, q.count());
        try testing.expectEqualStrings("muki", q.get("name").?);
        try testing.expectEqualStrings("waffle", q.get("food").?);
    }

    {
        q.clearRetainingCapacity();
        // Purposefully bad format with no keys or values.
        const captured = (try s.get_bundle(
            testing.allocator,
            "/item/2112.22121/price_float?",
            captures[0..],
            &q,
        )).?;
        defer testing.allocator.free(captured.duped);
        defer for (captured.duped) |dupe| testing.allocator.free(dupe);
        try testing.expectEqual(Route.init("/item/%f/price_float"), captured.route);
        try testing.expectEqual(2112.22121, captured.captures[0].float);
        try testing.expectEqual(0, q.count());
    }

    {
        q.clearRetainingCapacity();
        // Purposefully bad format with incomplete key/value pair.
        const captured = s.get_bundle(testing.allocator, "/item/100/price/283.21?help", captures[0..], &q);
        try testing.expectError(error.MissingValue, captured);
    }

    {
        q.clearRetainingCapacity();
        // Purposefully bad format with incomplete key/value pair.
        const captured = s.get_bundle(testing.allocator, "/item/100/price/283.21?help=", captures[0..], &q);
        try testing.expectError(error.MissingValue, captured);
    }

    {
        q.clearRetainingCapacity();
        // Purposefully bad format with invalid charactes.
        const captured = s.get_bundle(
            testing.allocator,
            "/item/999/price/100.221?page_count=pages=2020&abc=200",
            captures[0..],
            &q,
        );
        try testing.expectError(error.MalformedPair, captured);
    }
}
