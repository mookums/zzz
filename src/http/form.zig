const std = @import("std");
const assert = std.debug.assert;

const AnyCaseStringMap = @import("../core/any_case_string_map.zig").AnyCaseStringMap;
const Context = @import("context.zig").Context;

pub fn decode_alloc(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var list = try std.ArrayListUnmanaged(u8).initCapacity(allocator, input.len);
    defer list.deinit(allocator);

    var input_index: usize = 0;
    while (input_index < input.len) {
        defer input_index += 1;
        const byte = input[input_index];
        switch (byte) {
            '%' => {
                if (input_index + 2 >= input.len) return error.InvalidEncoding;
                list.appendAssumeCapacity(
                    try std.fmt.parseInt(u8, input[input_index + 1 .. input_index + 3], 16),
                );
                input_index += 2;
            },
            '+' => list.appendAssumeCapacity(' '),
            else => list.appendAssumeCapacity(byte),
        }
    }

    return list.toOwnedSlice(allocator);
}

fn parse_from(comptime name: []const u8, comptime T: type, value: []const u8) !T {
    switch (@typeInfo(T)) {
        .Int => |info| {
            return switch (info.signedness) {
                .unsigned => try std.fmt.parseUnsigned(T, value, 10),
                .signed => try std.fmt.parseInt(T, value, 10),
            };
        },
        .Float => |_| {
            return try std.fmt.parseFloat(T, value);
        },
        .Optional => |info| {
            return @as(T, try parse_from(name, info.child, value));
        },
        else => switch (T) {
            []const u8 => return value,
            bool => return std.mem.eql(u8, value, "true"),
            else => std.debug.panic("Unsupported field type \"{s}\"", .{@typeName(T)}),
        },
    }
}

fn parse_struct(comptime T: type, map: *const AnyCaseStringMap) !T {
    var ret: T = undefined;
    assert(@typeInfo(T) == .Struct);
    const struct_info = @typeInfo(T).Struct;
    inline for (struct_info.fields) |field| {
        const maybe_value_str: ?[]const u8 = map.get(field.name);

        if (maybe_value_str) |value| {
            @field(ret, field.name) = try parse_from(field.name, field.type, value);
        } else if (field.default_value) |default| {
            @field(ret, field.name) = @as(*const field.type, @ptrCast(@alignCast(default))).*;
        } else if (@typeInfo(field.type) == .Optional) {
            @field(ret, field.name) = null;
        } else return error.FieldEmpty;
    }

    return ret;
}

/// Parses Form data from a request body in `x-www-form-urlencoded` format.
pub fn Form(comptime T: type) type {
    return struct {
        pub fn parse(ctx: *const Context) !T {
            var m = AnyCaseStringMap.init(ctx.allocator);
            defer m.deinit();

            const map: *const AnyCaseStringMap = map: {
                if (ctx.request.body) |body| {
                    var pairs = std.mem.splitScalar(u8, body, '&');
                    while (pairs.next()) |pair| {
                        var kv = std.mem.splitScalar(u8, pair, '=');

                        const key = kv.next() orelse return error.MalformedForm;
                        const decoded_key = try decode_alloc(ctx.allocator, key);

                        const value = kv.next() orelse return error.MalformedForm;
                        const decoded_value = try decode_alloc(ctx.allocator, value);

                        assert(kv.next() == null);
                        try m.putNoClobber(decoded_key, decoded_value);
                    }
                } else return error.BodyEmpty;
                break :map &m;
            };

            return parse_struct(T, map);
        }
    };
}

/// Parses Form data from request URL query parameters.
pub fn Query(comptime T: type) type {
    return struct {
        pub fn parse(ctx: *const Context) !T {
            return parse_struct(T, ctx.queries);
        }
    };
}
