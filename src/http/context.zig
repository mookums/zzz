const std = @import("std");
const log = std.log.scoped(.@"zzz/context");

const RoutingTrie = @import("routing_trie.zig").RoutingTrie;
const TokenMatch = @import("routing_trie.zig").TokenMatch;
const Token = @import("routing_trie.zig").Token;

const Capture = union(TokenMatch) {
    Unsigned: TokenMatch.Unsigned.as_type(),
    Signed: TokenMatch.Signed.as_type(),
    Float: TokenMatch.Float.as_type(),
    String: TokenMatch.String.as_type(),
};

pub fn Extractor(comptime M: TokenMatch) type {
    return struct {
        pub fn extract(ctx: Context, n: u64) !?M.as_type() {
            const extracted = try ctx.extract(M, n);

            if (extracted) |inner| {
                switch (M) {
                    .Unsigned => return inner.Unsigned,
                    .Signed => return inner.Signed,
                    .Float => return inner.Float,
                    .String => return inner.String,
                }
            }

            return null;
        }

        pub fn extract_or(ctx: Context, n: u64, or_value: M.as_type()) !M.as_type() {
            const extracted = try ctx.extract(M, n);

            if (extracted) |inner| {
                switch (M) {
                    .Unsigned => return inner.Unsigned,
                    .Signed => return inner.Signed,
                    .Float => return inner.Float,
                    .String => return inner.String,
                }
            }

            return or_value;
        }
    };
}

pub const Context = struct {
    path: []const u8,
    /// Buffer for anything to use.
    /// Owned by zzz.
    buffer: []u8,

    pub fn init(path: []const u8, buffer: []u8) Context {
        return Context{ .path = path, .buffer = buffer };
    }

    /// Extracts the n-th occurance of this match.
    pub fn extract(self: Context, match: TokenMatch, n: u64) !?Capture {
        var count: u64 = 1;
        var iter = std.mem.tokenizeScalar(u8, self.path, '/');

        while (iter.next()) |chunk| {
            switch (match) {
                .Unsigned => {
                    if (std.fmt.parseInt(TokenMatch.Unsigned.as_type(), chunk, 10)) |value| {
                        if (count == n) {
                            return Capture{ .Unsigned = value };
                        } else {
                            count += 1;
                        }
                    } else |_| {}
                },
                .Signed => {
                    if (std.fmt.parseInt(TokenMatch.Signed.as_type(), chunk, 10)) |value| {
                        if (count == n) {
                            return Capture{ .Signed = value };
                        } else {
                            count += 1;
                        }
                    } else |_| {}
                },
                .Float => {
                    if (std.fmt.parseFloat(TokenMatch.Float.as_type(), chunk)) |value| {
                        if (count == n) {
                            return Capture{ .Float = value };
                        } else {
                            count += 1;
                        }
                    } else |_| {}
                },
                .String => if (count == n) {
                    return Capture{ .String = chunk };
                } else {
                    count += 1;
                },
            }
        }

        return null;
    }
};
