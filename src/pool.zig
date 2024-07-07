const std = @import("std");

// Not Thread Safe.
pub fn Pool(comptime T: type, comptime size: comptime_int) type {
    return struct {
        const Self = @This();
        // Buffer for the Pool.
        items: [size]T,

        /// Initalizes our items buffer as undefined.
        pub fn init(init_hook: ?*const fn (buffer: []T, args: anytype) void, args: anytype) Self {
            var self = Self{ .items = [_]T{undefined} ** size };

            if (init_hook) |hook| {
                @call(.auto, hook, .{ self.items[0..], args });
            }

            return self;
        }

        /// Deinitalizes our items buffer with a passed in hook.
        pub fn deinit(self: *Self, deinit_hook: ?*const fn (buffer: []T) void) void {
            if (deinit_hook) |hook| {
                @call(.auto, hook, .{self.items[0..]});
            }
        }

        pub fn get(self: *Self, index: usize) *T {
            return &self.items[index];
        }
    };
}

const testing = std.testing;

test "Pool Initalization (integer)" {
    const byte_pool = Pool(u8, 1024).init(struct {
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

test "Pool Initalization & Deinit (ArrayList)" {
    var list_pool = Pool(std.ArrayList(u8), 256).init(struct {
        fn init_hook(buffer: []std.ArrayList(u8), allocator: anytype) void {
            for (buffer) |*item| {
                item.* = std.ArrayList(u8).init(allocator);
            }
        }
    }.init_hook, testing.allocator);

    defer list_pool.deinit(struct {
        fn deinit_hook(buffer: []std.ArrayList(u8)) void {
            for (buffer) |*item| {
                item.deinit();
            }
        }
    }.deinit_hook);

    for (&list_pool.items, 0..) |*item, i| {
        try item.appendNTimes(0, i);
    }

    for (list_pool.items, 0..) |item, i| {
        try testing.expectEqual(item.items.len, i);
    }
}

test "Pool BufferPool ([][]u8)" {
    var buffer_pool = Pool([1024]u8, 1024).init(null, .{});

    for (&buffer_pool.items) |*item| {
        std.mem.copyForwards(u8, item, "ABCDEF");
    }

    for (buffer_pool.items) |item| {
        try testing.expectEqualStrings("ABCDEF", item[0..6]);
    }
}
