const std = @import("std");

const SearchTrieError = error{NotPresent};

/// This is a trie that should only be created during startup to provide an easy way to parse streams in.
/// This allows us to do optimistic matching.
pub fn SearchTrie(comptime V: type) type {
    return struct {
        const SearchTrieNode = struct {
            value: ?V = null,
            // Only supports letters and digits.
            children: [36]?*SearchTrieNode = undefined,

            pub fn init(allocator: std.mem.Allocator) *SearchTrieNode {
                var node = allocator.create(SearchTrieNode) catch unreachable;
                node.* = SearchTrieNode{ .value = null, .children = allocator.alloc(?*SearchTrieNode, 36) catch unreachable };
                for (0..node.children.len) |i| {
                    node.children[i] = null;
                }
                return node;
            }

            pub fn deinit(self: SearchTrieNode, allocator: std.mem.Allocator) void {
                for (self.children) |child| {
                    if (child) |c| {
                        c.deinit(allocator);
                        allocator.destroy(c);
                    }
                }

                allocator.free(self.children);
            }
        };

        // We want a stream oriented iterator.
        // this means that we can pass in slices and go from there to match on.

        const StreamIteratorOptions = struct {
            optimistic: bool = true,
        };

        fn StreamIterator(root: *SearchTrieNode, options: StreamIteratorOptions) type {
            return struct {
                node: *SearchTrieNode,
                options: options,
                const SelfIter = @This();

                pub fn init() SelfIter {
                    return SelfIter{ .node = root };
                }

                /// Given a character, it will follow the tree.
                pub fn next(self: SelfIter, char: u8) SearchTrieError!?V {
                    if (self.node.children[byteToKey(char)]) |child| {
                        // If optimistic,
                        if (options.optimistic) {
                            var valid_count = 0;
                            for (self.node.children) |_| {
                                valid_count += 1;
                            }

                            if (valid_count == 1) {
                                // This is the only one so deep match it.
                                
                                var search_node = child;
                                while(search_node.value == null) {

                                }
                            }
                        }

                        self.node = child;
                        return self.node.value;
                    } else {
                        return SearchTrieError.NotPresent;
                    }
                }
            };
        }

        allocator: std.mem.Allocator,
        root: *SearchTrieNode,
        const Self = @This();

        inline fn byteToKey(c: u8) usize {
            switch (c) {
                0...9 => return @as(usize, c),
                'a'...'z' => return @as(usize, c - @as(u8, 'a') + 10),
                'A'...'Z' => return @as(usize, c - @as(u8, 'A') + 10),
                else => return 0,
            }
        }

        pub fn init(allocator: std.mem.Allocator, keys: []const []const u8, values: []const V) Self {
            const root = SearchTrieNode.init(allocator);

            for (0..keys.len) |key_idx| {
                const key = keys[key_idx];
                var search_node = root;
                for (0..key.len) |char_idx| {
                    const char = key[char_idx];
                    const trie_key = byteToKey(char);
                    if (search_node.children[trie_key]) |n| {
                        // If this character exists, continue the search.
                        search_node = n;
                    } else {
                        // If this character doesn't exist, make it and continue.
                        const new_node = SearchTrieNode.init(allocator);
                        search_node.*.children[trie_key] = new_node;
                        search_node = new_node;
                    }

                    // If at the end...
                    if (char_idx == key.len - 1) {
                        search_node.value = values[key_idx];
                    }
                }
            }

            return Self{ .allocator = allocator, .root = root };
        }

        pub fn get(self: Self, key: []const u8) ?V {
            var search_root = self.root;

            for (key) |char| {
                if (search_root.children[byteToKey(char)]) |node| {
                    search_root = node;
                } else {
                    return null;
                }
            }

            return search_root.value.?;
        }

        pub fn deinit(self: Self) void {
            for (self.root.children) |child| {
                if (child) |c| {
                    c.deinit(self.allocator);
                    self.allocator.destroy(c);
                }
            }

            self.allocator.free(self.root.children);
            self.allocator.destroy(self.root);
        }
    };
}

const testing = std.testing;

test "SearchTrie Creation" {
    const keys: []const []const u8 = &.{
        "abc",
        "abb",
        "a",
        "acc",
        "asdyasdaa",
        "fsfafasa212",
        "asf2222",
        "kfkfkfpw",
        "abbb",
    };

    const values: []const usize = &.{
        0,
        2,
        100,
        5505,
        222,
        2414,
        22,
        9,
        2992,
    };

    const trie = SearchTrie(usize).init(testing.allocator, keys, values);
    defer trie.deinit();

    for (0..keys.len) |i| {
        try testing.expectEqual(trie.get(keys[i]), values[i]);
    }
}
