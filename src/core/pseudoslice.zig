const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/core/pseudoslice");

// The Pseudoslice will basically stitch together two different buffers, using
// a third provided buffer as the output.
pub const Pseudoslice = struct {
    first: []const u8,
    second: []const u8,
    shared: []u8,
    len: usize,

    pub fn init(first: []const u8, second: []const u8, shared: []u8) Pseudoslice {
        return Pseudoslice{
            .first = first,
            .second = second,
            .shared = shared,
            .len = first.len + second.len,
        };
    }

    /// Operates like a slice. That means it does not capture the end.
    /// Start is an inclusive bound and end is an exclusive bound.
    pub fn get(self: *const Pseudoslice, start: usize, end: usize) []const u8 {
        assert(end >= start);
        assert(self.shared.len >= end - start);
        const clamped_end = @min(end, self.len);

        if (start < self.first.len) {
            if (clamped_end <= self.first.len) {
                // within first slice
                return self.first[start..clamped_end];
            } else {
                // across both slices
                const first_len = self.first.len - start;
                const second_len = clamped_end - self.first.len;
                const total_len = clamped_end - start;

                if (self.first.ptr == self.shared.ptr) {
                    // just copy over the second.
                    std.mem.copyForwards(u8, self.shared[self.first.len..], self.second[0..second_len]);
                    return self.shared[start..clamped_end];
                } else {
                    // copy both over.
                    std.mem.copyForwards(u8, self.shared[0..first_len], self.first[start..]);
                    std.mem.copyForwards(u8, self.shared[first_len..], self.second[0..second_len]);
                    return self.shared[0..total_len];
                }
            }
        } else {
            // within second slice
            const second_start = start - self.first.len;
            const second_end = clamped_end - self.first.len;
            return self.second[second_start..second_end];
        }
    }
};

const testing = std.testing;

test "Pseudoslice General" {
    var buffer = [_]u8{0} ** 1024;
    const value = "hello, my name is muki";
    var pseudo = Pseudoslice.init(value[0..6], value[6..], buffer[0..]);

    for (0..pseudo.len) |i| {
        for (0..i) |j| {
            try testing.expectEqualStrings(value[j..i], pseudo.get(j, i));
        }
    }
}

test "Pseudoslice Empty Second" {
    var buffer = [_]u8{0} ** 1024;
    const value = "hello, my name is muki";
    var pseudo = Pseudoslice.init(value[0..], &.{}, buffer[0..]);

    for (0..pseudo.len) |i| {
        try testing.expectEqualStrings(value[0..i], pseudo.get(0, i));
    }
}

test "Pseudoslice First and Shared Same" {
    const buffer = try testing.allocator.alloc(u8, 1024);
    defer testing.allocator.free(buffer);

    const value = "hello, my name is muki";
    std.mem.copyForwards(u8, buffer, value[0..6]);

    var pseudo = Pseudoslice.init(buffer[0..6], value[6..], buffer);

    for (0..pseudo.len) |i| {
        for (0..i) |j| {
            try testing.expectEqualStrings(value[j..i], pseudo.get(j, i));
        }
    }
}
