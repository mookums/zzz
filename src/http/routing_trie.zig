const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/routing_trie");

const Route = @import("lib.zig").Route;

fn TokenHashMap(comptime V: type) type {
    return std.HashMap(Token, V, struct {
        pub fn hash(self: @This(), input: Token) u64 {
            _ = self;

            const bytes = blk: {
                switch (input) {
                    .Fragment => |inner| break :blk inner,
                    .Match => |inner| break :blk @tagName(inner),
                }
            };

            return std.hash.Crc32.hash(bytes);
        }

        pub fn eql(self: @This(), first: Token, second: Token) bool {
            _ = self;

            const result = blk: {
                switch (first) {
                    .Fragment => |f_inner| {
                        switch (second) {
                            .Fragment => |s_inner| break :blk std.mem.eql(u8, f_inner, s_inner),
                            else => break :blk false,
                        }
                    },
                    .Match => |f_inner| {
                        switch (second) {
                            .Match => |s_inner| break :blk f_inner == s_inner,
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
    Fragment = 0,
    Match = 1,
};

pub const TokenMatch = enum {
    Unsigned,
    Signed,
    Float,
    String,

    pub fn as_type(match: TokenMatch) type {
        switch (match) {
            .Unsigned => return u64,
            .Signed => return i64,
            .Float => return f64,
            .String => return []const u8,
        }
    }
};

pub const Token = union(TokenEnum) {
    Fragment: []const u8,
    Match: TokenMatch,

    pub fn parse_chunk(chunk: []const u8) Token {
        if (std.mem.startsWith(u8, chunk, "%")) {
            // Needs to be only % and an identifier.
            assert(chunk.len == 2);

            switch (chunk[1]) {
                'i', 'd' => return .{ .Match = .Signed },
                'u' => return .{ .Match = .Unsigned },
                'f' => return .{ .Match = .Float },
                's' => return .{ .Match = .String },
                else => @panic("Unsupported Match!"),
            }
        } else {
            return .{ .Fragment = chunk };
        }
    }
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
                Token{ .Fragment = "" },
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
            std.debug.print("Token: {any}\n", .{node_ptr.token});
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
                    try Node.init(
                        self.allocator,
                        token,
                        null,
                    ),
                );

                current = current.children.get(token).?;
            }
        }

        current.route = route;
    }

    pub fn get_route(self: RoutingTrie, path: []const u8) ?Route {
        // We need some way of also returning the capture groups here.
        var iter = std.mem.tokenizeScalar(u8, path, '/');

        var current = self.root;

        while (iter.next()) |chunk| {
            const fragment = Token{ .Fragment = chunk };

            // If it is the fragment, match it here.
            if (current.children.get(fragment)) |child| {
                current = child;
                continue;
            }

            // Match on Integers.
            if (std.fmt.parseInt(TokenMatch.Signed.as_type(), chunk, 10)) |_| {
                const int_fragment = Token{ .Match = .Signed };
                if (current.children.get(int_fragment)) |child| {
                    current = child;
                    continue;
                }
            } else |_| {}

            if (std.fmt.parseInt(TokenMatch.Unsigned.as_type(), chunk, 10)) |_| {
                const uint_fragment = Token{ .Match = .Unsigned };
                if (current.children.get(uint_fragment)) |child| {
                    current = child;
                    continue;
                }
            } else |_| {}

            // Match on Float.
            if (std.fmt.parseFloat(TokenMatch.Float.as_type(), chunk)) |_| {
                const float_fragment = Token{ .Match = .Float };
                if (current.children.get(float_fragment)) |child| {
                    current = child;
                    continue;
                }
            } else |_| {}

            // Match on String as last option.
            const string_fragment = Token{ .Match = .String };
            if (current.children.get(string_fragment)) |child| {
                current = child;
                continue;
            }

            return null;
        }

        return current.route;
    }
};

const testing = std.testing;

test "Chunk Parsing (Fragment)" {
    const chunk = "thisIsAFragment";
    const token: Token = Token.parse_chunk(chunk);

    switch (token) {
        .Fragment => |inner| try testing.expectEqualStrings(chunk, inner),
        .Match => return error.IncorrectTokenParsing,
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
        TokenMatch.Signed,
        TokenMatch.Signed,
        TokenMatch.Unsigned,
        TokenMatch.Float,
        TokenMatch.String,
    };

    for (chunks, matches) |chunk, match| {
        const token: Token = Token.parse_chunk(chunk);

        switch (token) {
            .Fragment => return error.IncorrectTokenParsing,
            .Match => |inner| try testing.expectEqual(match, inner),
        }
    }
}

test "Path Parsing (Mixed)" {
    const path = "/item/%i/description";

    const parsed: [3]Token = .{
        .{ .Fragment = "item" },
        .{ .Match = .Signed },
        .{ .Fragment = "description" },
    };

    var iter = std.mem.tokenizeScalar(u8, path, '/');

    for (parsed) |expected| {
        const token = Token.parse_chunk(iter.next().?);
        switch (token) {
            .Fragment => |inner| try testing.expectEqualStrings(expected.Fragment, inner),
            .Match => |inner| try testing.expectEqual(expected.Match, inner),
        }
    }
}

test "Custom Hashing" {
    var s = TokenHashMap(bool).init(testing.allocator);
    {
        try s.put(.{ .Fragment = "item" }, true);
        try s.put(.{ .Fragment = "thisisfalse" }, false);

        const state = s.get(.{ .Fragment = "item" }).?;
        try testing.expect(state);

        const should_be_false = s.get(.{ .Fragment = "thisisfalse" }).?;
        try testing.expect(!should_be_false);
    }

    {
        try s.put(.{ .Match = .Unsigned }, true);
        try s.put(.{ .Match = .Float }, false);
        try s.put(.{ .Match = .String }, false);

        const state = s.get(.{ .Match = .Unsigned }).?;
        try testing.expect(state);

        const should_be_false = s.get(.{ .Match = .Float }).?;
        try testing.expect(!should_be_false);

        const string_state = s.get(.{ .Match = .String }).?;
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

    try s.add_route("/item", Route.init());
    try s.add_route("/item/%i/description", Route.init());
    try s.add_route("/item/%i/hello", Route.init());
    try s.add_route("/item/%f/price_float", Route.init());
    try s.add_route("/item/name/%s", Route.init());
    try s.add_route("/item/list", Route.init());

    try testing.expectEqual(null, s.get_route("/item/name"));
    try testing.expectEqual(Route.init(), s.get_route("/item/name/HELLO"));

    try testing.expectEqual(null, s.get_route("/settings"));
    try testing.expectEqual(Route.init(), s.get_route("/item"));

    try testing.expectEqual(Route.init(), s.get_route("/item/200/hello"));
    try testing.expectEqual(null, s.get_route("/item/10.12/hello"));

    try testing.expectEqual(Route.init(), s.get_route("/item/99999.1000/price_float"));
    try testing.expectEqual(null, s.get_route("/item/10/price_float"));
}
