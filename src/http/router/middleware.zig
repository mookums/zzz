const std = @import("std");
const log = std.log.scoped(.@"zzz/router/middleware");
const assert = std.debug.assert;

const Runtime = @import("tardy").Runtime;

const wrap = @import("../../core/wrapping.zig").wrap;
const Pseudoslice = @import("../../core/pseudoslice.zig").Pseudoslice;
const Server = @import("../server.zig").Server;

const Mime = @import("../mime.zig").Mime;
const Route = @import("route.zig").Route;
const HandlerWithData = @import("route.zig").HandlerWithData;
const Context = @import("../context.zig").Context;
const Respond = @import("../response.zig").Respond;

pub const Layer = union(enum) {
    /// Route
    route: Route,
    /// Middleware
    middleware: MiddlewareWithData,
};

pub const Next = struct {
    context: *const Context,
    middlewares: []const MiddlewareWithData,
    handler: HandlerWithData,

    pub fn run(self: *Next) !Respond {
        if (self.middlewares.len > 0) {
            const middleware = self.middlewares[0];
            self.middlewares = self.middlewares[1..];
            return try middleware.func(self, middleware.data);
        } else return try self.handler.handler(self.context, self.handler.data);
    }
};

pub const MiddlewareFn = *const fn (*Next, usize) anyerror!Respond;
pub fn TypedMiddlewareFn(comptime T: type) type {
    return *const fn (*Next, T) anyerror!Respond;
}

pub const MiddlewareWithData = struct {
    func: MiddlewareFn,
    data: usize,
};

pub const Middleware = struct {
    inner: MiddlewareWithData,

    pub fn init(data: anytype, func: TypedMiddlewareFn(@TypeOf(data))) Middleware {
        return .{
            .inner = .{
                .func = @ptrCast(func),
                .data = wrap(usize, data),
            },
        };
    }

    pub fn layer(self: Middleware) Layer {
        return .{ .middleware = self.inner };
    }
};
