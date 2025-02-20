const std = @import("std");
const assert = std.debug.assert;

/// Special values for Wrapped types.
const Wrapped = enum(usize) { null = 0, true = 1, false = 2, void = 3 };

/// Wraps the given value into a specified integer type.
/// The value must fit within the size of the given I.
pub fn wrap(comptime I: type, value: anytype) I {
    assert(@typeInfo(I) == .Int);
    assert(@typeInfo(I).Int.signedness == .unsigned);

    if (comptime @bitSizeOf(@TypeOf(value)) > @bitSizeOf(I)) {
        @compileError("type: " ++ @typeName(value) ++ " is larger than given integer (" ++ @typeName(I) ++ ")");
    }

    return context: {
        switch (comptime @typeInfo(@TypeOf(value))) {
            .Pointer => break :context @intFromPtr(value),
            .Void => break :context @intFromEnum(Wrapped.void),
            .Int => |info| {
                const uint = @Type(std.builtin.Type{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = info.bits,
                    },
                });
                break :context @intCast(@as(uint, @bitCast(value)));
            },
            .ComptimeInt => break :context @intCast(value),
            .Float => |info| {
                const uint = @Type(std.builtin.Type{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = info.bits,
                    },
                });
                break :context @intCast(@as(uint, @bitCast(value)));
            },
            .ComptimeFloat => break :context @intCast(@as(I, @bitCast(value))),
            .Struct => |info| {
                const uint = @Type(std.builtin.Type{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = @bitSizeOf(info.backing_integer.?),
                    },
                });
                break :context @intCast(@as(uint, @bitCast(value)));
            },
            .Bool => break :context if (value) @intFromEnum(Wrapped.true) else @intFromEnum(Wrapped.false),
            .Optional => break :context if (value) |v| wrap(I, v) else @intFromEnum(Wrapped.null),
            else => @compileError("wrapping unsupported type: " ++ @typeName(@TypeOf(value))),
        }
    };
}

/// Unwraps a specified type from an underlying value.
/// The value must be an unsigned integer type, typically a usize.
pub fn unwrap(comptime T: type, value: anytype) T {
    const I = @TypeOf(value);
    assert(@typeInfo(I) == .Int);
    assert(@typeInfo(I).Int.signedness == .unsigned);
    if (comptime @bitSizeOf(@TypeOf(T)) > @bitSizeOf(I)) {
        @compileError("type: " ++ @typeName(value) ++ "is larger than given integer (" ++ @typeName(T) ++ ")");
    }

    return context: {
        switch (comptime @typeInfo(T)) {
            .Pointer => break :context @ptrFromInt(value),
            .Void => break :context {},
            .Int => |info| {
                const uint = @Type(std.builtin.Type{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = info.bits,
                    },
                });
                break :context @bitCast(@as(uint, @intCast(value)));
            },
            .Float => |info| {
                const uint = @Type(std.builtin.Type{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = info.bits,
                    },
                });
                const float = @Type(std.builtin.Type{
                    .Float = .{
                        .bits = info.bits,
                    },
                });
                break :context @as(float, @bitCast(@as(uint, @intCast(value))));
            },
            .Struct => |info| {
                const uint = @Type(std.builtin.Type{
                    .Int = .{
                        .signedness = .unsigned,
                        .bits = @bitSizeOf(info.backing_integer.?),
                    },
                });
                break :context @bitCast(@as(uint, @intCast(value)));
            },
            .Bool => {
                assert(value == @intFromEnum(Wrapped.true) or value == @intFromEnum(Wrapped.false));
                break :context if (value == @intFromEnum(Wrapped.false)) false else true;
            },
            .Optional => |info| break :context if (value == @intFromEnum(Wrapped.null))
                null
            else
                unwrap(info.child, value),
            else => unreachable,
        }
    };
}

const testing = std.testing;

test "wrap/unwrap - integers" {
    try testing.expectEqual(@as(usize, 42), wrap(usize, @as(u8, 42)));
    try testing.expectEqual(@as(usize, 42), wrap(usize, @as(u16, 42)));
    try testing.expectEqual(@as(usize, 42), wrap(usize, @as(u32, 42)));

    try testing.expectEqual(@as(usize, 42), wrap(usize, @as(i8, 42)));
    try testing.expectEqual(@as(usize, 42), wrap(usize, @as(i16, 42)));
    try testing.expectEqual(@as(usize, 42), wrap(usize, @as(i32, 42)));

    try testing.expectEqual(@as(u8, 42), unwrap(u8, @as(usize, 42)));
    try testing.expectEqual(@as(i16, 42), unwrap(i16, @as(usize, 42)));
}

test "wrap/unwrap - floats" {
    const pi_32: f32 = 3.14159;
    const pi_64: f64 = 3.14159;

    const wrapped_f32 = wrap(usize, pi_32);
    const wrapped_f64 = wrap(usize, pi_64);

    try testing.expectEqual(pi_32, unwrap(f32, wrapped_f32));
    try testing.expectEqual(pi_64, unwrap(f64, wrapped_f64));
}

test "wrap/unwrap - booleans" {
    try testing.expectEqual(@as(usize, @intFromEnum(Wrapped.true)), wrap(usize, true));
    try testing.expectEqual(@as(usize, @intFromEnum(Wrapped.false)), wrap(usize, false));

    try testing.expectEqual(true, unwrap(bool, @as(usize, @intFromEnum(Wrapped.true))));
    try testing.expectEqual(false, unwrap(bool, @as(usize, @intFromEnum(Wrapped.false))));
}

test "wrap/unwrap - optionals" {
    const optional_int: ?i32 = 42;
    const optional_none: ?i32 = null;

    try testing.expectEqual(@as(usize, 42), wrap(usize, optional_int));
    try testing.expectEqual(@as(usize, 0), wrap(usize, optional_none));

    try testing.expectEqual(@as(?i32, 42), unwrap(?i32, @as(usize, 42)));
    try testing.expectEqual(@as(?i32, null), unwrap(?i32, @as(usize, 0)));
}

test "wrap/unwrap - void" {
    try testing.expectEqual(@as(usize, @intFromEnum(Wrapped.void)), wrap(usize, {}));
    try testing.expectEqual({}, unwrap(void, @as(usize, @intFromEnum(Wrapped.void))));
}

test "wrap/unwrap - pointers" {
    var value: i32 = 42;
    const ptr = &value;

    const wrapped = wrap(usize, ptr);
    const unwrapped = unwrap(*i32, wrapped);

    try testing.expectEqual(&value, unwrapped);
    try testing.expectEqual(@as(i32, 42), unwrapped.*);
}
