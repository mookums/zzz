const std = @import("std");
const Method = std.http.Method;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Route = struct {
    handlers: [9]?*const fn (request: Request) Response = [_]?*const fn (request: Request) Response{null} ** 9,

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
            else => unreachable,
        };
    }

    pub fn init() Route {
        return Route{ .handlers = [_]?*const fn (request: Request) Response{null} ** 9 };
    }

    pub fn get_handler(self: Route, method: Method) ?*const fn (request: Request) Response {
        return self.handlers[method_to_index(method)];
    }

    pub fn get(self: Route, handler_fn: *const fn (request: Request) Response) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.GET)] = handler_fn;
        return Route{ .path = self.path, .handlers = new_handlers };
    }

    pub fn post(self: Route, handler_fn: *const fn (request: Request) Response) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.POST)] = handler_fn;
        return Route{ .path = self.path, .handlers = self.handlers };
    }

    pub fn put(self: Route, handler_fn: *const fn (request: Request) Response) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.PUT)] = handler_fn;
        return Route{ .path = self.path, .handlers = self.handlers };
    }

    pub fn delete(self: Route, handler_fn: *const fn (request: Request) Response) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.DELETE)] = handler_fn;
        return Route{ .path = self.path, .handlers = self.handlers };
    }

    pub fn patch(self: Route, handler_fn: *const fn (request: Request) Response) Route {
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(.PATCH)] = handler_fn;
        return Route{ .path = self.path, .handlers = self.handlers };
    }
};
