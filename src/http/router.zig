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

/// Default not found handler: send a plain text response.
pub fn default_not_found_handler(comptime Server: type, comptime AppState: type) _Route(Server, AppState).HandlerFn {
    const Context = _Context(Server, AppState);

    return struct {
        fn not_found_handler(ctx: *Context) !void {
            try ctx.respond(.{
                .status = .@"Not Found",
                .mime = Mime.TEXT,
                .body = "Not found.",
            });
        }
    }.not_found_handler;
}

/// Initialize a router with the given routes.
pub fn Router(comptime Server: type, comptime AppState: type) type {
    return struct {
        const Self = @This();
        const RoutingTrie = _RoutingTrie(Server, AppState);
        const FoundRoute = RoutingTrie.FoundRoute;
        const Route = _Route(Server, AppState);
        const Context = _Context(Server, AppState);

        /// Router configuration structure.
        pub const Configuration = struct {
            not_found_handler: Route.HandlerFn = default_not_found_handler(Server, AppState),
        };

        routes: RoutingTrie,
        not_found_route: Route,
        state: AppState,

        pub fn init(state: AppState, comptime _routes: []const Route, comptime configuration: Configuration) Self {
            const self = Self{
                // Initialize the routing tree from the given routes.
                .routes = comptime RoutingTrie.init(_routes),
                .not_found_route = comptime Route.init("").all(configuration.not_found_handler),
                .state = state,
            };

            return self;
        }

        pub fn get_route_from_host(self: Self, path: []const u8, captures: []Capture, queries: *QueryMap) !FoundRoute {
            return try self.routes.get_route(path, captures, queries) orelse {
                queries.clearRetainingCapacity();
                return FoundRoute{ .route = self.not_found_route, .captures = captures[0..0], .queries = queries };
            };
        }
    };
}
