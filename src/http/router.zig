const std = @import("std");
const log = std.log.scoped(.@"zzz/http/router");
const assert = std.debug.assert;

const _Route = @import("router/route.zig").Route;

const Capture = @import("router/routing_trie.zig").Capture;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Mime = @import("mime.zig").Mime;
const _Context = @import("context.zig").Context;

const _RoutingTrie = @import("router/routing_trie.zig").RoutingTrie;
const QueryMap = @import("router/routing_trie.zig").QueryMap;

/// Initialize a router with the given routes.
pub fn Router(comptime Server: type, comptime AppState: type) type {
    return struct {
        const Self = @This();
        const RoutingTrie = _RoutingTrie(Server, AppState);
        const FoundRoute = RoutingTrie.FoundRoute;
        const Route = _Route(Server, AppState);
        const Context = _Context(Server, AppState);

        routes: RoutingTrie,
        not_found_route: ?Route = null,
        state: AppState,
        /// This makes the router immutable, also making it
        /// thread-safe when shared.
        locked: bool = false,

        pub fn init(state: AppState, comptime _routes: []const Route) Self {
            const self = Self{
                // Initialize the routing tree from the given routes.
                .routes = comptime RoutingTrie.init(_routes),
                .state = state,
                .locked = false,
            };

            return self;
        }

        pub fn serve_not_found(self: *Self, route: Route) void {
            assert(!self.locked);
            self.not_found_route = route;
        }

        pub fn get_route_from_host(self: Self, path: []const u8, captures: []Capture, queries: *QueryMap) !FoundRoute {
            const base_404_route = comptime Route.init("").get(struct {
                fn not_found_handler(ctx: *Context) !void {
                    try ctx.respond(.{
                        .status = .@"Not Found",
                        .mime = Mime.HTML,
                        .body = "",
                    });
                }
            }.not_found_handler);

            return try self.routes.get_route(path, captures, queries) orelse {
                queries.clearRetainingCapacity();
                if (self.not_found_route) |not_found| {
                    return FoundRoute{ .route = not_found, .captures = captures[0..0], .queries = queries };
                } else return FoundRoute{ .route = base_404_route, .captures = captures[0..0], .queries = queries };
            };
        }
    };
}
