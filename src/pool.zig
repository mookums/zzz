const std = @import("std");

pub fn ComptimePool(comptime T: type, comptime size: comptime_int) type {
    return struct {
        const Self = @This();
        // Buffer for the ComptimePool.
        items: []T,

        /// Initalizes our items buffer as undefined.
        pub fn init(init_hook: ?*const fn (buffer: []T, args: anytype) void, args: anytype) Self {
            var items = [_]T{undefined} ** size;
            var self = Self{ .items = items[0..] };

            if (init_hook) |hook| {
                @call(.auto, hook, .{ self.items[0..], args });
            }

            return self;
        }

        /// Deinitalizes our items buffer with a passed in hook.
        pub fn deinit(self: Self, deinit_hook: ?*const fn (buffer: []T, args: anytype) void, args: anytype) void {
            if (deinit_hook) |hook| {
                @call(.auto, hook, .{ self.items, args });
            }
        }

        pub fn get(self: *Self, index: usize) T {
            return self.items[index];
        }

        pub fn get_ptr(self: *Self, index: usize) *T {
            return &self.items[index];
        }
    };
}

pub fn Pool(comptime T: type) type {
    return struct {
        const Self = @This();
        // Buffer for the Pool.
        items: []T,
        allocator: std.mem.Allocator,

        /// Initalizes our items buffer as undefined.
        pub fn init(allocator: std.mem.Allocator, size: u32, init_hook: ?*const fn (buffer: []T, args: anytype) void, args: anytype) !Self {
            const items: []T = try allocator.alloc(T, size);
            const self = Self{ .allocator = allocator, .items = items };

            if (init_hook) |hook| {
                @call(.auto, hook, .{ self.items, args });
            }

            return self;
        }

        /// Deinitalizes our items buffer with a passed in hook.
        pub fn deinit(self: Self, deinit_hook: ?*const fn (buffer: []T, args: anytype) void, args: anytype) void {
            if (deinit_hook) |hook| {
                @call(.auto, hook, .{ self.items, args });
            }

            self.allocator.free(self.items);
        }

        pub fn get(self: Self, index: usize) T {
            return self.items[index];
        }

        pub fn get_ptr(self: *Self, index: usize) *T {
            return &self.items[index];
        }
    };
}

const testing = std.testing;

test "ComptimePool Initalization (integer)" {
    const byte_pool = ComptimePool(u8, 1024).init(struct {
        fn init_hook(buffer: []u8, _: anytype) void {
            for (buffer) |*item| {
                item.* = 2;
            }
        }
    }.init_hook, .{});

    for (byte_pool.items) |item| {
        try testing.expectEqual(item, 2);
    }
}

test "ComptimePool Initalization & Deinit (ArrayList)" {
    var list_pool = ComptimePool(std.ArrayList(u8), 256).init(struct {
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

test "ComptimePool BufferComptimePool ([][]u8)" {
    const buffer_pool = ComptimePool([1024]u8, 1024).init(null, .{});

    for (buffer_pool.items) |*item| {
        std.mem.copyForwards(u8, item, "ABCDEF");
    }

    for (buffer_pool.items) |item| {
        try testing.expectEqualStrings("ABCDEF", item[0..6]);
    }
}

test "Pool Initalization (integer)" {
    const byte_pool = try Pool(u8).init(testing.allocator, 1024, struct {
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
    const buffer_pool = try Pool([1024]u8).init(testing.allocator, 1024, null, .{});
    defer buffer_pool.deinit(null, null);

    for (buffer_pool.items) |*item| {
        std.mem.copyForwards(u8, item, "ABCDEF");
    }

    for (buffer_pool.items) |item| {
        try testing.expectEqualStrings("ABCDEF", item[0..6]);
    }
}
