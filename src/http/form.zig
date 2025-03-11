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

fn parse_from(allocator: std.mem.Allocator, comptime T: type, comptime name: []const u8, value: []const u8) !T {
    return switch (@typeInfo(T)) {
        .int => |info| switch (info.signedness) {
            .unsigned => try std.fmt.parseUnsigned(T, value, 10),
            .signed => try std.fmt.parseInt(T, value, 10),
        },
        .float => try std.fmt.parseFloat(T, value),
        .optional => |info| @as(T, try parse_from(allocator, info.child, name, value)),
        .@"enum" => std.meta.stringToEnum(T, value) orelse return error.InvalidEnumValue,
        .bool => std.mem.eql(u8, value, "true"),
        else => switch (T) {
            []const u8 => try allocator.dupe(u8, value),
            [:0]const u8 => try allocator.dupeZ(u8, value),
            else => std.debug.panic("Unsupported field type \"{s}\"", .{@typeName(T)}),
        },
    };
}

fn parse_struct(allocator: std.mem.Allocator, comptime T: type, map: *const AnyCaseStringMap) !T {
    var ret: T = undefined;
    assert(@typeInfo(T) == .@"struct");
    const struct_info = @typeInfo(T).@"struct";
    inline for (struct_info.fields) |field| {
        const entry = map.getEntry(field.name);

        if (entry) |e| {
            @field(ret, field.name) = try parse_from(allocator, field.type, field.name, e.value_ptr.*);
        } else if (field.defaultValue()) |default| {
            @field(ret, field.name) = default;
        } else if (@typeInfo(field.type) == .optional) {
            @field(ret, field.name) = null;
        } else return error.FieldEmpty;
    }

    return ret;
}

fn construct_map_from_body(allocator: std.mem.Allocator, m: *AnyCaseStringMap, body: []const u8) !void {
    var pairs = std.mem.splitScalar(u8, body, '&');

    while (pairs.next()) |pair| {
        const field_idx = std.mem.indexOfScalar(u8, pair, '=') orelse return error.MissingSeperator;
        if (pair.len < field_idx + 2) return error.MissingValue;

        const key = pair[0..field_idx];
        const value = pair[(field_idx + 1)..];

        if (std.mem.indexOfScalar(u8, value, '=') != null) return error.MalformedPair;

        const decoded_key = try decode_alloc(allocator, key);
        errdefer allocator.free(decoded_key);

        const decoded_value = try decode_alloc(allocator, value);
        errdefer allocator.free(decoded_value);

        // Allow for duplicates (like with the URL params),
        // The last one just takes precedent.
        const entry = try m.getOrPut(decoded_key);
        if (entry.found_existing) {
            allocator.free(decoded_key);
            allocator.free(entry.value_ptr.*);
        }
        entry.value_ptr.* = decoded_value;
    }
}

/// Parses Form data from a request body in `x-www-form-urlencoded` format.
pub fn Form(comptime T: type) type {
    return struct {
        pub fn parse(allocator: std.mem.Allocator, ctx: *const Context) !T {
            var m = AnyCaseStringMap.init(ctx.allocator);
            defer {
                var it = m.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    allocator.free(entry.value_ptr.*);
                }
                m.deinit();
            }

            if (ctx.request.body) |body|
                try construct_map_from_body(allocator, &m, body)
            else
                return error.BodyEmpty;

            return parse_struct(allocator, T, &m);
        }
    };
}

/// Parses Form data from request URL query parameters.
pub fn Query(comptime T: type) type {
    return struct {
        pub fn parse(allocator: std.mem.Allocator, ctx: *const Context) !T {
            return parse_struct(allocator, T, ctx.queries);
        }
    };
}

const testing = std.testing;

test "FormData: Parsing from Body" {
    const UserRole = enum { admin, visitor };
    const User = struct { id: u32, name: []const u8, age: u8, role: UserRole };
    const body: []const u8 = "id=10&name=John&age=12&role=visitor";

    var m = AnyCaseStringMap.init(testing.allocator);
    defer {
        var it = m.iterator();
        while (it.next()) |entry| {
            testing.allocator.free(entry.key_ptr.*);
            testing.allocator.free(entry.value_ptr.*);
        }
        m.deinit();
    }
    try construct_map_from_body(testing.allocator, &m, body);

    const parsed = try parse_struct(testing.allocator, User, &m);
    defer testing.allocator.free(parsed.name);

    try testing.expectEqual(10, parsed.id);
    try testing.expectEqualSlices(u8, "John", parsed.name);
    try testing.expectEqual(12, parsed.age);
    try testing.expectEqual(UserRole.visitor, parsed.role);
}

test "FormData: Parsing Missing Fields" {
    const User = struct { id: u32, name: []const u8, age: u8 };
    const body: []const u8 = "id=10";

    var m = AnyCaseStringMap.init(testing.allocator);
    defer {
        var it = m.iterator();
        while (it.next()) |entry| {
            testing.allocator.free(entry.key_ptr.*);
            testing.allocator.free(entry.value_ptr.*);
        }
        m.deinit();
    }

    try construct_map_from_body(testing.allocator, &m, body);

    const parsed = parse_struct(testing.allocator, User, &m);
    try testing.expectError(error.FieldEmpty, parsed);
}

test "FormData: Parsing Missing Value" {
    const body: []const u8 = "abc=abc&id=";

    var m = AnyCaseStringMap.init(testing.allocator);
    defer {
        var it = m.iterator();
        while (it.next()) |entry| {
            testing.allocator.free(entry.key_ptr.*);
            testing.allocator.free(entry.value_ptr.*);
        }
        m.deinit();
    }

    const result = construct_map_from_body(testing.allocator, &m, body);
    try testing.expectError(error.MissingValue, result);
}
