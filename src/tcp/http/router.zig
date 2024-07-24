const std = @import("std");
const Route = @import("route.zig").Route;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Mime = @import("mime.zig").Mime;
const log = std.log.scoped(.router);

pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.StringHashMap(Route),

    // TODO: Routing needs to be partly re-done. We need to have a single
    // path have support for a variety of handler fns depending on method.
    pub fn init(allocator: std.mem.Allocator) Router {
        const routes = std.StringHashMap(Route).init(allocator);
        return Router{ .allocator = allocator, .routes = routes };
    }

    pub fn deinit(self: Router) void {
        self.routes.deinit();
    }

    pub fn serve_embedded_file(self: *Router, path: []const u8, comptime mime: Mime, comptime bytes: []const u8) !void {
        const route = Route{ .path = path, .methods = &.{.GET}, .handler_fn = struct {
            pub fn handler_fn(_: Request) Response {
                return Response.init(.OK, mime, bytes);
            }
        }.handler_fn };

        try self.serve_route(route);
    }

    pub fn serve_route(self: *Router, route: Route) !void {
        try self.routes.put(route.path, route);
    }

    pub fn get_route_from_host(self: Router, host: []const u8) ?Route {
        return self.routes.get(host);
    }
};
