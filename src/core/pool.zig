const std = @import("std");
const assert = std.debug.assert;

fn Borrow(comptime T: type) type {
    return struct {
        index: usize,
        item: *T,
    };
}

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        // Buffer for the Pool.
        items: []T,
        dirty: std.DynamicBitSet,
        full: bool = false,

        /// Initalizes our items buffer as undefined.
        pub fn init(
            allocator: std.mem.Allocator,
            size: u32,
            init_hook: ?*const fn (buffer: []T, args: anytype) void,
            args: anytype,
        ) !Self {
            const items: []T = try allocator.alloc(T, size);
            const self = Self{
                .allocator = allocator,
                .items = items,
                .dirty = try std.DynamicBitSet.initEmpty(allocator, size),
            };

            if (init_hook) |hook| {
                @call(.auto, hook, .{ self.items, args });
            }

            return self;
        }

        /// Deinitalizes our items buffer with a passed in hook.
        pub fn deinit(
            self: *Self,
            deinit_hook: ?*const fn (buffer: []T, args: anytype) void,
            args: anytype,
        ) void {
            if (deinit_hook) |hook| {
                @call(.auto, hook, .{ self.items, args });
            }

            self.allocator.free(self.items);
            self.dirty.deinit();
        }

        fn get(self: Self, index: usize) T {
            return self.items[index];
        }

        fn get_ptr(self: *Self, index: usize) *T {
            return &self.items[index];
        }

        // The id is supposed to be a unique identification for
        // this element. It gets hashed and used to find an empty element.
        //
        // Returns a tuple of the index into the pool and a pointer to the item.
        // Returns null otherwise.
        pub fn borrow(self: *Self, id: u32) !Borrow(T) {
            const bytes = std.mem.toBytes(id)[0..];
            const hash = @mod(std.hash.Wyhash.hash(0, bytes), self.items.len);

            if (!self.dirty.isSet(hash)) {
                self.dirty.set(hash);
                return Borrow(T){ .index = hash, .item = self.get_ptr(hash) };
            }

            // Linear probing if the first fails.
            // This ensures we end up using the whole Pool.
            for (0..self.items.len) |i| {
                const index = @mod(hash + i, self.items.len);

                if (!self.dirty.isSet(index)) {
                    self.dirty.set(index);
                    return Borrow(T){ .index = index, .item = self.get_ptr(index) };
                }
            }

            self.full = true;
            return error.Full;
        }

        // Releases the item with the given index back to the Pool.
        // Asserts that the given index was borrowed.
        pub fn release(self: *Self, index: usize) void {
            assert(self.dirty.isSet(index));
            self.dirty.unset(index);
            self.full = false;
        }
    };
}

const testing = std.testing;

test "Pool Initalization (integer)" {
    var byte_pool = try Pool(u8).init(testing.allocator, 1024, struct {
        fn init_hook(buffer: []u8, _: anytype) void {
            for (buffer) |*item| {
                item.* = 2;
            }
        }
    }.init_hook, .{});
    defer byte_pool.deinit(null, null);

    for (byte_pool.items) |item| {
        try testing.expectEqual(item, 2);
    }
}

test "Pool Initalization & Deinit (ArrayList)" {
    var list_pool = try Pool(std.ArrayList(u8)).init(testing.allocator, 256, struct {
        fn init_hook(buffer: []std.ArrayList(u8), allocator: anytype) void {
            for (buffer) |*item| {
                item.* = std.ArrayList(u8).init(allocator);
            }
        }
    }.init_hook, testing.allocator);

    defer list_pool.deinit(struct {
        fn deinit_hook(buffer: []std.ArrayList(u8), _: anytype) void {
            for (buffer) |*item| {
                item.deinit();
            }
        }
    }.deinit_hook, null);

    for (list_pool.items, 0..) |*item, i| {
        try item.appendNTimes(0, i);
    }

    for (list_pool.items, 0..) |item, i| {
        try testing.expectEqual(item.items.len, i);
    }
}

test "Pool BufferPool ([][]u8)" {
    var buffer_pool = try Pool([1024]u8).init(testing.allocator, 1024, null, .{});
    defer buffer_pool.deinit(null, null);

    for (buffer_pool.items) |*item| {
        std.mem.copyForwards(u8, item, "ABCDEF");
    }

    for (buffer_pool.items) |item| {
        try testing.expectEqualStrings("ABCDEF", item[0..6]);
    }
}

test "Pool Borrowing" {
    var byte_pool = try Pool(u8).init(testing.allocator, 1024, struct {
        fn init_hook(buffer: []u8, _: anytype) void {
            for (buffer) |*item| {
                item.* = 3;
            }
        }
    }.init_hook, .{});
    defer byte_pool.deinit(null, null);

    for (0..1024) |i| {
        const x = try byte_pool.borrow(@intCast(i));
        try testing.expectEqual(3, x.item.*);
    }
}
