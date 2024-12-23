const Route = @import("route.zig").Route;
const MiddlewareWithData = @import("middleware.zig").MiddlewareWithData;

const MiddlewarePair = struct {
    pre: MiddlewareWithData,
    post: MiddlewareWithData,
};

pub const Layer = union(enum) {
    /// Route
    route: Route,
    /// Pre-Route Middleware
    pre: MiddlewareWithData,
    /// Post-Route Middleware
    post: MiddlewareWithData,
    /// Pair of Middleware
    pair: MiddlewarePair,
};
