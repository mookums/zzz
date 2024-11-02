const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/route");
const Method = @import("method.zig").Method;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const Context = @import("context.zig").Context;

pub fn Route(comptime Server: type) type {
    return struct {
        const Self = @This();
        pub const HandlerFn = *const fn (context: *Context(Server), data: *const anyopaque) anyerror!void;
        fn TypedHandlerFn(comptime T: type) type {
            return *const fn (context: *Context(Server), data: T) anyerror!void;
        }
        const HandlerWithData = struct {
            handler: HandlerFn,
            data: *anyopaque,
        };

        handlers: [9]?HandlerWithData = [_]?HandlerWithData{null} ** 9,

        fn method_to_index(method: Method) u32 {
            return switch (method) {
                .GET => 0,
                .HEAD => 1,
                .POST => 2,
                .PUT => 3,
                .DELETE => 4,
                .CONNECT => 5,
                .OPTIONS => 6,
                .TRACE => 7,
                .PATCH => 8,
            };
        }

        pub fn init() Self {
            return Self{ .handlers = [_]?HandlerWithData{null} ** 9 };
        }

        /// Returns a comma delinated list of allowed Methods for this route. This
        /// is meant to be used as the value for the 'Allow' header in the Response.
        pub fn get_allowed(self: Self, allocator: std.mem.Allocator) ![]const u8 {
            // This gets allocated within the context of the connection's arena.
            const allowed_size = comptime blk: {
                var size = 0;
                for (std.meta.tags(Method)) |method| {
                    size += @tagName(method).len + 1;
                }
                break :blk size;
            };

            const buffer = try allocator.alloc(u8, allowed_size);

            var current: []u8 = "";
            inline for (std.meta.tags(Method)) |method| {
                if (self.handlers[@intFromEnum(method)] != null) {
                    current = std.fmt.bufPrint(buffer, "{s},{s}", .{ @tagName(method), current }) catch unreachable;
                }
            }

            if (current.len == 0) {
                return current;
            } else {
                return current[0 .. current.len - 1];
            }
        }

        pub fn get_handler(self: Self, method: Method) ?HandlerWithData {
            return self.handlers[method_to_index(method)];
        }

        inline fn inner_route(
            comptime method: Method,
            self: Self,
            data: anytype,
            handler_fn: TypedHandlerFn(@TypeOf(data)),
        ) Self {
            // You can either give a void (if you don't want to pass data through) or a pointer.
            comptime assert(@typeInfo(@TypeOf(data)) == .Pointer or @typeInfo(@TypeOf(data)) == .Void);
            const inner_data = switch (comptime @typeInfo(@TypeOf(data))) {
                .Void => @constCast(&data),
                .Pointer => data,
                else => unreachable,
            };
            var new_handlers = self.handlers;
            new_handlers[comptime method_to_index(method)] = .{
                .handler = @ptrCast(handler_fn),
                .data = inner_data,
            };
            return Self{ .handlers = new_handlers };
        }

        pub fn get(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
            return inner_route(.GET, self, data, handler_fn);
        }

        pub fn head(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
            return inner_route(.HEAD, self, data, handler_fn);
        }

        pub fn post(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
            return inner_route(.POST, self, data, handler_fn);
        }

        pub fn put(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
            return inner_route(.PUT, self, data, handler_fn);
        }

        pub fn delete(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
            return inner_route(.DELETE, self, data, handler_fn);
        }

        pub fn connect(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
            return inner_route(.CONNECT, self, data, handler_fn);
        }

        pub fn options(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
            return inner_route(.OPTIONS, self, data, handler_fn);
        }

        pub fn trace(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
            return inner_route(.TRACE, self, data, handler_fn);
        }

        pub fn patch(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
            return inner_route(.PATCH, self, data, handler_fn);
        }
    };
}
