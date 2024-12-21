const std = @import("std");
const assert = std.debug.assert;

const Pool = @import("tardy").Pool;

pub fn CaseStringMap(comptime T: type) type {
    return struct {
        const Self = @This();
        const InnerPool = Pool(Entry);
        const PoolIterator = InnerPool.Iterator;

        const Entry = struct {
            hash: u32,
            key: []const u8,
            data: T,
        };

        pool: InnerPool,

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            const pool = try Pool(Entry).init(allocator, size, null, null);
            return .{ .pool = pool };
        }

        pub fn deinit(self: *Self) void {
            self.pool.deinit(null, null);
        }

        pub fn put(self: *Self, name: []const u8, data: T) !void {
            const name_hash = hash(name);
            const entry = try self.pool.borrow_hint(@intCast(name_hash));
            entry.item.* = .{ .key = name, .hash = name_hash, .data = data };
        }

        pub fn put_assume_capacity(self: *Self, name: []const u8, data: T) void {
            assert(self.pool.clean() > 0);
            const name_hash = hash(name);
            const entry = self.pool.borrow_hint(@intCast(name_hash)) catch unreachable;
            entry.item.* = .{ .key = name, .hash = name_hash, .data = data };
        }

        pub fn get(self: *const Self, name: []const u8) ?T {
            const name_hash = hash(name);

            var iter = self.pool.iterator();
            while (iter.next()) |entry| {
                if (entry.hash == name_hash) {
                    return entry.data;
                }
            }

            return null;
        }

        pub fn iterator(self: *Self) PoolIterator {
            return self.pool.iterator();
        }

        pub fn num_clean(self: *const Self) usize {
            return self.pool.clean();
        }

        pub fn dirty(self: *const Self) usize {
            return self.pool.dirty.count();
        }

        pub fn clear(self: *Self) void {
            // unset all of the dirty bits, effectively clearing it.
            self.pool.dirty.unsetAll();
        }

        fn hash(name: []const u8) u32 {
            var h = std.hash.Fnv1a_32.init();
            for (name) |byte| {
                h.update(&.{std.ascii.toLower(byte)});
            }
            return h.final();
        }
    };
}

const testing = std.testing;

test "CaseStringMap: Add Stuff" {
    var csm = try CaseStringMap([]const u8).init(testing.allocator, 2);
    defer csm.deinit();

    try csm.put("Content-Length", "100");
    csm.put_assume_capacity("Host", "localhost:9999");

    const content_length = csm.get("content-length");
    try testing.expect(content_length != null);

    const host = csm.get("host");
    try testing.expect(host != null);
}
