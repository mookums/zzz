const std = @import("std");
const log = std.log.scoped(.@"zzz/http/route");
const Method = @import("method.zig").Method;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const Context = @import("context.zig").Context;

pub const RouteHandlerFn = *const fn (context: *Context) void;

pub const Route = struct {
    handlers: [9]?RouteHandlerFn = [_]?RouteHandlerFn{null} ** 9,

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

    pub fn init() Route {
        return Route{ .handlers = [_]?RouteHandlerFn{null} ** 9 };
    }

    /// Returns a comma delinated list of allowed Methods for this route. This
    /// is meant to be used as the value for the 'Allow' header in the Response.
    pub fn get_allowed(self: Route, allocator: std.mem.Allocator) ![]const u8 {
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

    pub fn get_handler(self: Route, method: Method) ?RouteHandlerFn {
        return self.handlers[method_to_index(method)];
    }

    pub fn get(self: Route, handler_fn: RouteHandlerFn) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.GET)] = handler_fn;
        return Route{ .handlers = new_handlers };
    }

    pub fn head(self: Route, handler_fn: RouteHandlerFn) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.HEAD)] = handler_fn;
        return Route{ .handlers = new_handlers };
    }

    pub fn post(self: Route, handler_fn: RouteHandlerFn) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.POST)] = handler_fn;
        return Route{ .handlers = new_handlers };
    }

    pub fn put(self: Route, handler_fn: RouteHandlerFn) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.PUT)] = handler_fn;
        return Route{ .handlers = new_handlers };
    }

    pub fn delete(self: Route, handler_fn: RouteHandlerFn) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.DELETE)] = handler_fn;
        return Route{ .handlers = new_handlers };
    }

    pub fn connect(self: Route, handler_fn: RouteHandlerFn) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.CONNECT)] = handler_fn;
        return Route{ .handlers = new_handlers };
    }

    pub fn options(self: Route, handler_fn: RouteHandlerFn) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.OPTIONS)] = handler_fn;
        return Route{ .handlers = new_handlers };
    }

    pub fn trace(self: Route, handler_fn: RouteHandlerFn) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.TRACE)] = handler_fn;
        return Route{ .handlers = new_handlers };
    }

    pub fn patch(self: Route, handler_fn: RouteHandlerFn) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.PATCH)] = handler_fn;
        return Route{ .handlers = new_handlers };
    }
};
