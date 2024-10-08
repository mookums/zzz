const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/routing_trie");

const CaseStringMap = @import("case_string_map.zig").CaseStringMap;
const Route = @import("lib.zig").Route;

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

// These tokens are for the Routes when assembling the
// Routing Trie. This allows for every sub-path to be
// parsed into a token and assembled later.

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

pub const QueryMap = CaseStringMap([]const u8);

pub const Capture = union(TokenMatch) {
    unsigned: TokenMatch.unsigned.as_type(),
    signed: TokenMatch.signed.as_type(),
    float: TokenMatch.float.as_type(),
    string: TokenMatch.string.as_type(),
    remaining: TokenMatch.remaining.as_type(),
};

pub const FoundRoute = struct {
    route: Route,
    captures: []Capture,
    queries: *QueryMap,
};

// This RoutingTrie is deleteless. It only can create new routes or update existing ones.
pub const RoutingTrie = struct {
    pub const Node = struct {
        allocator: std.mem.Allocator,
        token: Token,
        route: ?Route = null,
        children: TokenHashMap(*Node),

        pub fn init(allocator: std.mem.Allocator, token: Token, route: ?Route) !*Node {
            const node_ptr: *Node = try allocator.create(Node);
            node_ptr.* = Node{
                .allocator = allocator,
                .token = token,
                .route = route,
                .children = TokenHashMap(*Node).init(allocator),
            };

            return node_ptr;
        }

        pub fn deinit(self: *Node) void {
            var iter = self.children.valueIterator();

            while (iter.next()) |node| {
                node.*.deinit();
            }

            self.children.deinit();
            self.allocator.destroy(self);
        }
    };

    allocator: std.mem.Allocator,
    root: *Node,

    pub fn init(allocator: std.mem.Allocator) !RoutingTrie {
        return RoutingTrie{
            .allocator = allocator,
            .root = try Node.init(
                allocator,
                Token{ .fragment = "" },
                Route.init(),
            ),
        };
    }

    pub fn deinit(self: *RoutingTrie) void {
        self.root.deinit();
    }

    fn print_node(root: *Node) void {
        var iter = root.children.iterator();

        while (iter.next()) |entry| {
            const node_ptr = entry.value_ptr.*;
            std.io.getStdOut().writer().print(
                "Token: {any}\n",
                .{node_ptr.token},
            ) catch return;
            print_node(entry.value_ptr.*);
        }
    }

    fn print(self: *RoutingTrie) void {
        print_node(self.root);
    }

    pub fn add_route(self: *RoutingTrie, path: []const u8, route: Route) !void {
        // This is where we will parse out the path.
        var iter = std.mem.tokenizeScalar(u8, path, '/');

        var current = self.root;
        while (iter.next()) |chunk| {
            const token: Token = Token.parse_chunk(chunk);
            if (current.children.get(token)) |child| {
                current = child;
            } else {
                try current.children.put(
                    token,
                    try Node.init(self.allocator, token, null),
                );

                current = current.children.get(token).?;
            }
        }

        current.route = route;
    }

    pub fn get_route(
        self: RoutingTrie,
        path: []const u8,
        captures: []Capture,
        queries: *QueryMap,
    ) ?FoundRoute {
        var capture_idx: usize = 0;

        queries.clearRetainingCapacity();

        const query_pos = std.mem.indexOfScalar(u8, path, '?');
        var iter = std.mem.tokenizeScalar(u8, path[0..(query_pos orelse path.len)], '/');
        var current = self.root;

        slash_loop: while (iter.next()) |chunk| {
            const fragment = Token{ .fragment = chunk };

            // If it is the fragment, match it here.
            if (current.children.get(fragment)) |child| {
                current = child;
                continue;
            }

            var matched = false;
            for (std.meta.tags(TokenMatch)) |token_type| {
                const token = Token{ .match = token_type };
                if (current.children.get(token)) |child| {
                    matched = true;
                    switch (token_type) {
                        .signed => if (std.fmt.parseInt(i64, chunk, 10)) |value| {
                            captures[capture_idx] = Capture{ .signed = value };
                        } else |_| continue,
                        .unsigned => if (std.fmt.parseInt(u64, chunk, 10)) |value| {
                            captures[capture_idx] = Capture{ .unsigned = value };
                        } else |_| continue,
                        .float => if (std.fmt.parseFloat(f64, chunk)) |value| {
                            captures[capture_idx] = Capture{ .float = value };
                        } else |_| continue,
                        .string => captures[capture_idx] = Capture{ .string = chunk },
                        // This ends the matching sequence and claims everything.
                        // Does not match the query statement!
                        .remaining => {
                            const rest = iter.buffer[(iter.index - chunk.len)..];
                            captures[capture_idx] = Capture{ .remaining = rest };
                            current.route = child.route.?;
                            capture_idx += 1;
                            break :slash_loop;
                        },
                    }

                    current = child;
                    capture_idx += 1;

                    if (capture_idx > captures.len) {
                        // Should return an error here but for now,
                        // itll just be a null.
                        return null;
                    }

                    break;
                }
            }

            // If we failed to match,
            // this is an invalid route.
            if (!matched) {
                return null;
            }
        }

        if (query_pos) |pos| {
            if (path.len > pos + 1) {
                var query_iter = std.mem.tokenizeScalar(u8, path[pos + 1 ..], '&');

                while (query_iter.next()) |chunk| {
                    if (queries.count() >= queries.capacity() / 2) {
                        return null;
                    }

                    const field_idx = std.mem.indexOfScalar(u8, chunk, '=') orelse break;
                    if (chunk.len < field_idx + 1) break;

                    const key = chunk[0..field_idx];
                    const value = chunk[(field_idx + 1)..];

                    assert(std.mem.indexOfScalar(u8, key, '=') == null);
                    assert(std.mem.indexOfScalar(u8, value, '=') == null);

                    queries.putAssumeCapacity(key, value);
                }
            }
        }

        const route = current.route orelse return null;
        return FoundRoute{
            .route = route,
            .captures = captures[0..capture_idx],
            .queries = queries,
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

test "Custom Hashing" {
    var s = TokenHashMap(bool).init(testing.allocator);
    {
        try s.put(.{ .fragment = "item" }, true);
        try s.put(.{ .fragment = "thisisfalse" }, false);

        const state = s.get(.{ .fragment = "item" }).?;
        try testing.expect(state);

        const should_be_false = s.get(.{ .fragment = "thisisfalse" }).?;
        try testing.expect(!should_be_false);
    }

    {
        try s.put(.{ .match = .unsigned }, true);
        try s.put(.{ .match = .float }, false);
        try s.put(.{ .match = .string }, false);

        const state = s.get(.{ .match = .unsigned }).?;
        try testing.expect(state);

        const should_be_false = s.get(.{ .match = .float }).?;
        try testing.expect(!should_be_false);

        const string_state = s.get(.{ .match = .string }).?;
        try testing.expect(!string_state);
    }

    defer s.deinit();
}

test "Constructing Routing from Path" {
    var s = try RoutingTrie.init(testing.allocator);
    defer s.deinit();

    try s.add_route("/item", Route.init());
    try s.add_route("/item/%i/description", Route.init());
    try s.add_route("/item/%i/hello", Route.init());
    try s.add_route("/item/%f/price_float", Route.init());
    try s.add_route("/item/name/%s", Route.init());
    try s.add_route("/item/list", Route.init());

    try testing.expectEqual(1, s.root.children.count());
}

test "Routing with Paths" {
    var s = try RoutingTrie.init(testing.allocator);
    defer s.deinit();

    var q = QueryMap.init(testing.allocator);
    try q.ensureTotalCapacity(8);
    defer q.deinit();

    var captures: [8]Capture = [_]Capture{undefined} ** 8;

    try s.add_route("/item", Route.init());
    try s.add_route("/item/%i/description", Route.init());
    try s.add_route("/item/%i/hello", Route.init());
    try s.add_route("/item/%f/price_float", Route.init());
    try s.add_route("/item/name/%s", Route.init());
    try s.add_route("/item/list", Route.init());

    try testing.expectEqual(null, s.get_route("/item/name", captures[0..], &q));

    {
        const captured = s.get_route("/item/name/HELLO", captures[0..], &q).?;

        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqualStrings("HELLO", captured.captures[0].string);
    }

    {
        const captured = s.get_route("/item/2112.22121/price_float", captures[0..], &q).?;

        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqual(2112.22121, captured.captures[0].float);
    }
}

test "Routing with Remaining" {
    var s = try RoutingTrie.init(testing.allocator);
    defer s.deinit();

    var q = QueryMap.init(testing.allocator);
    try q.ensureTotalCapacity(8);
    defer q.deinit();

    var captures: [8]Capture = [_]Capture{undefined} ** 8;

    try s.add_route("/item", Route.init());
    try s.add_route("/item/%f/price_float", Route.init());
    try s.add_route("/item/name/%r", Route.init());
    try s.add_route("/item/%i/price/%f", Route.init());

    try testing.expectEqual(null, s.get_route("/item/name", captures[0..], &q));

    {
        const captured = s.get_route("/item/name/HELLO", captures[0..], &q).?;
        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqualStrings("HELLO", captured.captures[0].remaining);
    }
    {
        const captured = s.get_route("/item/name/THIS/IS/A/FILE/SYSTEM/PATH.html", captures[0..], &q).?;
        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqualStrings("THIS/IS/A/FILE/SYSTEM/PATH.html", captured.captures[0].remaining);
    }

    {
        const captured = s.get_route("/item/2112.22121/price_float", captures[0..], &q).?;
        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqual(2112.22121, captured.captures[0].float);
    }

    {
        const captured = s.get_route("/item/100/price/283.21", captures[0..], &q).?;
        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqual(100, captured.captures[0].signed);
        try testing.expectEqual(283.21, captured.captures[1].float);
    }
}

test "Routing with Queries" {
    var s = try RoutingTrie.init(testing.allocator);
    defer s.deinit();

    var q = QueryMap.init(testing.allocator);
    try q.ensureTotalCapacity(8);
    defer q.deinit();

    var captures: [8]Capture = [_]Capture{undefined} ** 8;

    try s.add_route("/item", Route.init());
    try s.add_route("/item/%f/price_float", Route.init());
    try s.add_route("/item/name/%r", Route.init());
    try s.add_route("/item/%i/price/%f", Route.init());

    try testing.expectEqual(null, s.get_route("/item/name", captures[0..], &q));

    {
        const captured = s.get_route("/item/name/HELLO?name=muki&food=waffle", captures[0..], &q).?;
        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqualStrings("HELLO", captured.captures[0].remaining);
        try testing.expectEqual(2, q.count());
        try testing.expectEqualStrings("muki", q.get("name").?);
        try testing.expectEqualStrings("waffle", q.get("food").?);
    }

    {
        // Purposefully bad format with no keys or values.
        const captured = s.get_route("/item/2112.22121/price_float?", captures[0..], &q).?;
        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqual(2112.22121, captured.captures[0].float);
        try testing.expectEqual(0, q.count());
    }

    {
        // Purposefully bad format with incomplete key/value pair.
        const captured = s.get_route("/item/100/price/283.21?help", captures[0..], &q).?;
        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqual(100, captured.captures[0].signed);
        try testing.expectEqual(283.21, captured.captures[1].float);
        try testing.expectEqual(0, q.count());
    }

    {
        // Purposefully have too many queries.
        const captured = s.get_route("/item/100/price/283.21?a=1&b=2&c=3&d=4&e=5&f=6&g=7&h=8&i=9&j=10&k=11", captures[0..], &q);
        try testing.expectEqual(null, captured);
    }
}
