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

pub fn Form(comptime T: type) type {
    return struct {
        pub fn parse(ctx: *const Context) !T {
            var m = AnyCaseStringMap.init(ctx.allocator);
            defer m.deinit();

            var map: *const AnyCaseStringMap = if (ctx.request.body) |body| blk: {
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

                break :blk &m;
            } else ctx.queries;

            var ret: T = undefined;
            assert(@typeInfo(T) == .Struct);
            const struct_info = @typeInfo(T).Struct;
            inline for (struct_info.fields) |field| {
                const maybe_value_str: ?[]const u8 = map.get(field.name);

                if (maybe_value_str) |value| {
                    switch (field.type) {
                        []const u8 => @field(ret, field.name) = value,
                        bool => @field(ret, field.name) = std.mem.eql(u8, value, "true"),
                        else => switch (@typeInfo(field.type)) {
                            .Int => |info| {
                                @field(ret, field.name) = switch (info.signedness) {
                                    .unsigned => try std.fmt.parseUnsigned(field.type, value, 10),
                                    .signed => try std.fmt.parseInt(field.type, value, 10),
                                };
                            },
                            .Float => |_| {
                                @field(ret, field.name) = try std.fmt.parseFloat(field.type, value);
                            },
                            else => unreachable,
                        },
                    }
                } else if (field.default_value) |default| {
                    @field(ret, field.name) = @as(*const field.type, @ptrCast(@alignCast(default))).*;
                } else return error.FieldEmpty;
            }

            return ret;
        }
    };
}
