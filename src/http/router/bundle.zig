const MiddlewareWithData = @import("middleware.zig").MiddlewareWithData;
const Route = @import("route.zig").Route;

pub const Bundle = struct {
    pre: []const MiddlewareWithData,
    route: Route,
    post: []const MiddlewareWithData,
};
