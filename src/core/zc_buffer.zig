const std = @import("std");
const assert = std.debug.assert;

pub const ZeroCopyBuffer = struct {
    allocator: std.mem.Allocator,
    ptr: [*]u8,
    len: usize,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !ZeroCopyBuffer {
        const slice = try allocator.alloc(u8, capacity);
        return .{
            .allocator = allocator,
            .ptr = slice.ptr,
            .len = 0,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *ZeroCopyBuffer) void {
        self.allocator.free(self.ptr[0..self.capacity]);
    }

    pub fn as_slice(self: *ZeroCopyBuffer) []u8 {
        return self.ptr[0..self.len];
    }

    const SubsliceOptions = struct {
        start: ?usize = null,
        end: ?usize = null,
    };

    pub fn subslice(self: *ZeroCopyBuffer, options: SubsliceOptions) []u8 {
        const start: usize = options.start orelse 0;
        const end: usize = options.end orelse self.len;
        assert(start <= end);
        assert(end <= self.len);

        return self.ptr[start..end];
    }

    /// This returns a slice that you can write into for zero-copy uses.
    /// This is mostly used when we are passing a buffer to I/O then acting on it.
    ///
    /// The write area that is returned is ONLY valid until the next call of get_write_area
    /// or mark_written.
    pub fn get_write_area(self: *ZeroCopyBuffer, size: usize) ![]u8 {
        const available_space = self.capacity - self.len;
        if (available_space >= size) {
            return self.ptr[self.len .. self.len + size];
        } else {
            const old_slice = self.ptr[0..self.capacity];
            const new_size = try std.math.ceilPowerOfTwo(usize, self.capacity + size);

            if (self.allocator.resize(self.ptr[0..self.capacity], new_size)) {
                self.capacity = new_size;
            } else {
                const new_slice = try self.allocator.alloc(u8, new_size);
                @memcpy(new_slice[0..self.len], self.ptr[0..self.len]);
                self.allocator.free(old_slice);

                self.ptr = new_slice.ptr;
                self.capacity = new_slice.len;
            }

            assert(self.capacity - self.len >= size);
            return self.ptr[self.len .. self.len + size];
        }
    }

    pub fn get_write_area_assume_space(self: *ZeroCopyBuffer, size: usize) []u8 {
        assert(self.capacity - self.len >= size);
        return self.ptr[self.len .. self.len + size];
    }

    pub fn mark_written(self: *ZeroCopyBuffer, length: usize) void {
        assert(self.len + length <= self.capacity);
        self.len += length;
    }

    pub fn shrink_retaining_capacity(self: *ZeroCopyBuffer, new_size: usize) void {
        assert(new_size <= self.len);
        self.len = new_size;
    }

    pub fn clear_retaining_capacity(self: *ZeroCopyBuffer) void {
        self.len = 0;
    }

    pub fn clear_and_free(self: *ZeroCopyBuffer) void {
        self.allocator.free(self.ptr[0..self.capacity]);
        self.len = 0;
        self.capacity = 0;
    }
};

const testing = std.testing;

test "ZeroCopyBuffer: First" {
    const garbage: []const u8 = &[_]u8{212} ** 128;

    var zc = try ZeroCopyBuffer.init(testing.allocator, 512);
    defer zc.deinit();

    const write_area = try zc.get_write_area(garbage.len);
    @memcpy(write_area, garbage);
    zc.mark_written(write_area.len);

    try testing.expectEqualSlices(u8, garbage[0..], zc.as_slice()[0..write_area.len]);
}

test "ZeroCopyBuffer: Growth" {
    var zc = try ZeroCopyBuffer.init(testing.allocator, 16);
    defer zc.deinit();

    const large_data = &[_]u8{1} ** 32;
    const write_area = try zc.get_write_area(large_data.len);
    @memcpy(write_area, large_data);
    zc.mark_written(write_area.len);

    try testing.expect(zc.capacity >= 32);
    try testing.expectEqualSlices(u8, large_data, zc.as_slice());
}

test "ZeroCopyBuffer: Multiple Writes" {
    var zc = try ZeroCopyBuffer.init(testing.allocator, 64);
    defer zc.deinit();

    const data1 = "Hello, ";
    const data2 = "World!";

    const area1 = try zc.get_write_area(data1.len);
    @memcpy(area1, data1);
    zc.mark_written(area1.len);

    const area2 = try zc.get_write_area(data2.len);
    @memcpy(area2, data2);
    zc.mark_written(area2.len);

    try testing.expectEqualSlices(u8, "Hello, World!", zc.as_slice());
}

test "ZeroCopyBuffer: Zero Size Write" {
    var zc = try ZeroCopyBuffer.init(testing.allocator, 8);
    defer zc.deinit();

    const area = try zc.get_write_area(0);
    try testing.expect(area.len == 0);
    zc.mark_written(0);
    try testing.expect(zc.len == 0);
}
