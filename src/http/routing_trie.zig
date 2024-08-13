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

pub const Capture = union(TokenMatch) {
    Unsigned: TokenMatch.Unsigned.as_type(),
    Signed: TokenMatch.Signed.as_type(),
    Float: TokenMatch.Float.as_type(),
    String: TokenMatch.String.as_type(),
};

pub const CapturedRoute = struct {
    route: Route,
    captures: []Capture,
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

    pub fn get_route(self: RoutingTrie, path: []const u8, captures: []Capture) ?CapturedRoute {
        // We need some way of also returning the capture groups here.
        var capture_idx: usize = 0;
        var iter = std.mem.tokenizeScalar(u8, path, '/');

        var current = self.root;

        while (iter.next()) |chunk| {
            const fragment = Token{ .Fragment = chunk };

            // If it is the fragment, match it here.
            if (current.children.get(fragment)) |child| {
                current = child;
                continue;
            }

            var matched = false;
            for ([_]TokenMatch{ .Signed, .Unsigned, .Float, .String }) |token_type| {
                const token = Token{ .Match = token_type };
                if (current.children.get(token)) |child| {
                    matched = true;
                    switch (token_type) {
                        .Signed => if (std.fmt.parseInt(i64, chunk, 10)) |value| {
                            captures[capture_idx] = Capture{ .Signed = value };
                        } else |_| continue,
                        .Unsigned => if (std.fmt.parseInt(u64, chunk, 10)) |value| {
                            captures[capture_idx] = Capture{ .Unsigned = value };
                        } else |_| continue,
                        .Float => if (std.fmt.parseFloat(f64, chunk)) |value| {
                            captures[capture_idx] = Capture{ .Float = value };
                        } else |_| continue,
                        .String => captures[capture_idx] = Capture{ .String = chunk },
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

        if (current.route) |r| {
            return CapturedRoute{ .route = r, .captures = captures[0..capture_idx] };
        } else {
            return null;
        }
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
    try s.add_route("/item/%i/price/%f", Route.init());

    try testing.expectEqual(null, s.get_route("/item/name"));

    {
        const captured = s.get_route("/item/name/HELLO").?;
        defer captured.captures.deinit();

        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqualStrings("HELLO", captured.captures.items[0].String);
    }

    {
        const captured = s.get_route("/item/2112.22121/price_float").?;
        defer captured.captures.deinit();

        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqual(2112.22121, captured.captures.items[0].Float);
    }

    {
        const captured = s.get_route("/item/100/price/283.21").?;
        defer captured.captures.deinit();

        try testing.expectEqual(Route.init(), captured.route);
        try testing.expectEqual(100, captured.captures.items[0].Signed);
        try testing.expectEqual(283.21, captured.captures.items[1].Float);
    }
}
