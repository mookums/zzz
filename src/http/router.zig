const std = @import("std");
const Route = @import("route.zig").Route;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Mime = @import("mime.zig").Mime;
const log = std.log.scoped(.router);

pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.StringHashMap(Route),

    pub fn init(allocator: std.mem.Allocator) Router {
        const routes = std.StringHashMap(Route).init(allocator);
        return Router{ .allocator = allocator, .routes = routes };
    }

    pub fn deinit(self: Router) void {
        self.routes.deinit();
    }

    pub fn serve_fs_dir(self: *Router, dir_path: []const u8) !void {
        // We will be adding a new route to the Router, that will be "dir_path'
        _ = self;
        const dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        @panic("TODO");
    }

    pub fn serve_embedded_file(self: *Router, path: []const u8, comptime mime: ?Mime, comptime bytes: []const u8) !void {
        const route = Route.init(path).get(struct {
            pub fn handler_fn(_: Request) Response {
                return Response.init(.OK, mime, bytes);
            }
        }.handler_fn);

        try self.serve_route(route);
    }

    pub fn serve_route(self: *Router, route: Route) !void {
        try self.routes.put(route.path, route);
    }

    pub fn get_route_from_host(self: Router, host: []const u8) ?Route {
        return self.routes.get(host);
    }
};
