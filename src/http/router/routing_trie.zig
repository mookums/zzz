const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/routing_trie");

const CaseStringMap = @import("../../core/case_string_map.zig").CaseStringMap;
const _Route = @import("route.zig").Route;
const TokenHashMap = @import("token_hash_map.zig").TokenHashMap;

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

// This RoutingTrie is deleteless. It only can create new routes or update existing ones.
pub fn RoutingTrie(comptime Server: type, comptime AppState: type) type {
    return struct {
        const Self = @This();
        const Route = _Route(Server, AppState);

        /// Structure of a matched route.
        pub const FoundRoute = struct {
            route: Route,
            captures: []Capture,
            queries: *QueryMap,
        };

        /// Structure of a node of the trie.
        pub const Node = struct {
            pub const ChildrenMap = TokenHashMap(*const Node);

            token: Token,
            route: ?Route = null,
            children: ChildrenMap,

            /// Initialize a new empty node.
            pub fn init(token: Token, route: ?Route) Node {
                return Node{
                    .token = token,
                    .route = route,
                    .children = ChildrenMap.init_comptime(&[0]ChildrenMap.KV{}),
                };
            }

            /// Initialize a cloned node with a new child for the provided token.
            pub fn with_child(self: *const Node, token: Token, node: *const Node) Node {
                return Node{
                    .token = self.token,
                    .route = self.route,
                    .children = self.children.with_kvs(&[_]ChildrenMap.KV{.{ token, node }}),
                };
            }
        };

        root: Node = Node.init(.{ .fragment = "" }, null),

        /// Initialize the routing tree with the given routes.
        pub fn init(comptime routes: []const Route) Self {
            return (Self{}).with_routes(routes);
        }

        fn print_node(root: *const Node, depth: usize) void {
            for (root.children.values) |node| {
                var i: usize = 0;
                while (i < depth) : (i += 1) {
                    std.debug.print(" │  ", .{});
                }

                std.debug.print(" ├ ", .{});

                switch (node.token) {
                    .fragment => |inner| std.debug.print("Token: {s}", .{inner}),
                    .match => |match| std.debug.print("Token: Match {s}", .{@tagName(match)}),
                }
                if (node.route != null) {
                    std.debug.print("  ⃝", .{});
                }
                std.debug.print("\n", .{});

                print_node(node, depth + 1);
            }
        }

        pub fn print(self: *const Self) void {
            std.debug.print("Root: \n", .{});
            print_node(&(self.root), 0);
        }

        /// Initialize new trie node for the next token.
        fn _with_route(comptime node: *const Node, comptime iterator: *std.mem.TokenIterator(u8, .scalar), comptime route: Route) Node {
            if (iterator.next()) |chunk| {
                // Parse the current chunk.
                const token: Token = Token.parse_chunk(chunk);
                // Alter the child of the current node.
                return node.with_child(token, &(_with_route(
                    node.children.get_optional(token) orelse &(Node.init(token, null)),
                    iterator,
                    route,
                )));
            } else {
                // We reached the last node, returning it with the provided route.
                return Node{
                    .token = node.token,
                    .route = route,
                    .children = node.children,
                };
            }
        }

        /// Copy the current routing trie to add the provided route.
        pub fn with_route(comptime self: *const Self, comptime route: Route) Self {
            @setEvalBranchQuota(10000);

            // This is where we will parse out the path.
            comptime var iterator = std.mem.tokenizeScalar(u8, route.path, '/');

            return Self{
                .root = _with_route(&(self.root), &iterator, route),
            };
        }

        /// Copy the current routing trie to add all the provided routes.
        pub fn with_routes(comptime self: *const Self, comptime routes: []const Route) Self {
            comptime var current = self.*;
            inline for (routes) |route| {
                current = current.with_route(route);
            }
            return current;
        }

        pub fn get_route(
            self: Self,
            path: []const u8,
            captures: []Capture,
            queries: *QueryMap,
        ) !?FoundRoute {
            var capture_idx: usize = 0;

            queries.clearRetainingCapacity();
            const query_pos = std.mem.indexOfScalar(u8, path, '?');
            var iter = std.mem.tokenizeScalar(u8, path[0..(query_pos orelse path.len)], '/');

            var current = self.root;

            slash_loop: while (iter.next()) |chunk| {
                const fragment = Token{ .fragment = chunk };

                // If it is the fragment, match it here.
                if (current.children.get_optional(fragment)) |child| {
                    current = child.*;
                    continue;
                }

                var matched = false;
                for (std.meta.tags(TokenMatch)) |token_type| {
                    const token = Token{ .match = token_type };
                    if (current.children.get_optional(token)) |child| {
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
                            // Does not claim the query values.
                            .remaining => {
                                const rest = iter.buffer[(iter.index - chunk.len)..];
                                captures[capture_idx] = Capture{ .remaining = rest };

                                current = child.*;
                                capture_idx += 1;

                                break :slash_loop;
                            },
                        }

                        current = child.*;
                        capture_idx += 1;

                        if (capture_idx > captures.len) return error.TooManyCaptures;
                        break;
                    }
                }

                // If we failed to match, this is an invalid route.
                if (!matched) {
                    return null;
                }
            }

            if (query_pos) |pos| {
                if (path.len > pos + 1) {
                    var query_iter = std.mem.tokenizeScalar(u8, path[pos + 1 ..], '&');

                    while (query_iter.next()) |chunk| {
                        if (queries.count() >= queries.capacity() / 2) return null;

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

            return FoundRoute{
                .route = current.route orelse return null,
                .captures = captures[0..capture_idx],
                .queries = queries,
            };
        }
    };
}

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
    const Route = _Route(void, void);

    const s = comptime RoutingTrie(void, void).init(&[_]Route{
        Route.init("/item"),
        Route.init("/item/%i/description"),
        Route.init("/item/%i/hello"),
        Route.init("/item/%f/price_float"),
        Route.init("/item/name/%s"),
        Route.init("/item/list"),
    });

    try testing.expectEqual(1, s.root.children.keys.len);
}

test "Routing with Paths" {
    const Route = _Route(void, void);

    const s = comptime RoutingTrie(void, void).init(&[_]Route{
        Route.init("/item"),
        Route.init("/item/%i/description"),
        Route.init("/item/%i/hello"),
        Route.init("/item/%f/price_float"),
        Route.init("/item/name/%s"),
        Route.init("/item/list"),
    });

    var q = try QueryMap.init(testing.allocator, &[_][]const u8{}, &[_][]const u8{});
    try q.ensureTotalCapacity(testing.allocator, 8);
    defer q.deinit(testing.allocator);

    var captures: [8]Capture = [_]Capture{undefined} ** 8;

    try testing.expectEqual(null, try s.get_route("/item/name", captures[0..], &q));

    {
        const captured = (try s.get_route("/item/name/HELLO", captures[0..], &q)).?;

        try testing.expectEqual(Route.init("/item/name/%s"), captured.route);
        try testing.expectEqualStrings("HELLO", captured.captures[0].string);
    }

    {
        const captured = (try s.get_route("/item/2112.22121/price_float", captures[0..], &q)).?;

        try testing.expectEqual(Route.init("/item/%f/price_float"), captured.route);
        try testing.expectEqual(2112.22121, captured.captures[0].float);
    }
}

test "Routing with Remaining" {
    const Route = _Route(void, void);

    const s = comptime RoutingTrie(void, void).init(&[_]Route{
        Route.init("/item"),
        Route.init("/item/%f/price_float"),
        Route.init("/item/name/%r"),
        Route.init("/item/%i/price/%f"),
    });

    var q = try QueryMap.init(testing.allocator, &[_][]const u8{}, &[_][]const u8{});
    try q.ensureTotalCapacity(testing.allocator, 8);
    defer q.deinit(testing.allocator);

    var captures: [8]Capture = [_]Capture{undefined} ** 8;

    try testing.expectEqual(null, try s.get_route("/item/name", captures[0..], &q));

    {
        const captured = (try s.get_route("/item/name/HELLO", captures[0..], &q)).?;
        try testing.expectEqual(Route.init("/item/name/%r"), captured.route);
        try testing.expectEqualStrings("HELLO", captured.captures[0].remaining);
    }
    {
        const captured = (try s.get_route("/item/name/THIS/IS/A/FILE/SYSTEM/PATH.html", captures[0..], &q)).?;
        try testing.expectEqual(Route.init("/item/name/%r"), captured.route);
        try testing.expectEqualStrings("THIS/IS/A/FILE/SYSTEM/PATH.html", captured.captures[0].remaining);
    }

    {
        const captured = (try s.get_route("/item/2112.22121/price_float", captures[0..], &q)).?;
        try testing.expectEqual(Route.init("/item/%f/price_float"), captured.route);
        try testing.expectEqual(2112.22121, captured.captures[0].float);
    }

    {
        const captured = (try s.get_route("/item/100/price/283.21", captures[0..], &q)).?;
        try testing.expectEqual(Route.init("/item/%i/price/%f"), captured.route);
        try testing.expectEqual(100, captured.captures[0].signed);
        try testing.expectEqual(283.21, captured.captures[1].float);
    }
}

test "Routing with Queries" {
    const Route = _Route(void, void);

    const s = comptime RoutingTrie(void, void).init(&[_]Route{
        Route.init("/item"),
        Route.init("/item/%f/price_float"),
        Route.init("/item/name/%r"),
        Route.init("/item/%i/price/%f"),
    });

    var q = try QueryMap.init(testing.allocator, &[_][]const u8{}, &[_][]const u8{});
    try q.ensureTotalCapacity(testing.allocator, 8);
    defer q.deinit(testing.allocator);

    var captures: [8]Capture = [_]Capture{undefined} ** 8;

    try testing.expectEqual(null, try s.get_route("/item/name", captures[0..], &q));

    {
        const captured = (try s.get_route("/item/name/HELLO?name=muki&food=waffle", captures[0..], &q)).?;
        try testing.expectEqual(Route.init("/item/name/%r"), captured.route);
        try testing.expectEqualStrings("HELLO", captured.captures[0].remaining);
        try testing.expectEqual(2, q.count());
        try testing.expectEqualStrings("muki", q.get("name").?);
        try testing.expectEqualStrings("waffle", q.get("food").?);
    }

    {
        // Purposefully bad format with no keys or values.
        const captured = (try s.get_route("/item/2112.22121/price_float?", captures[0..], &q)).?;
        try testing.expectEqual(Route.init("/item/%f/price_float"), captured.route);
        try testing.expectEqual(2112.22121, captured.captures[0].float);
        try testing.expectEqual(0, q.count());
    }

    {
        // Purposefully bad format with incomplete key/value pair.
        const captured = (try s.get_route("/item/100/price/283.21?help", captures[0..], &q)).?;
        try testing.expectEqual(Route.init("/item/%i/price/%f"), captured.route);
        try testing.expectEqual(100, captured.captures[0].signed);
        try testing.expectEqual(283.21, captured.captures[1].float);
        try testing.expectEqual(0, q.count());
    }

    {
        // Purposefully have too many queries.
        const captured = try s.get_route(
            "/item/100/price/283.21?a=1&b=2&c=3&d=4&e=5&f=6&g=7&h=8&i=9&j=10&k=11",
            captures[0..],
            &q,
        );
        try testing.expectEqual(null, captured);
    }
}
