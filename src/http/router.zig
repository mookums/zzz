const std = @import("std");
const log = std.log.scoped(.@"zzz/http/router");
const assert = std.debug.assert;

const Layer = @import("router/middleware.zig").Layer;
const Route = @import("router/route.zig").Route;
const TypedHandlerFn = @import("router/route.zig").TypedHandlerFn;

const Bundle = @import("router/routing_trie.zig").Bundle;
const FoundBundle = @import("router/routing_trie.zig").FoundBundle;

const Capture = @import("router/routing_trie.zig").Capture;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Respond = @import("response.zig").Respond;
const Mime = @import("mime.zig").Mime;
const Context = @import("context.zig").Context;

const RoutingTrie = @import("router/routing_trie.zig").RoutingTrie;
const QueryMap = @import("router/routing_trie.zig").QueryMap;

/// Default not found handler: send a plain text response.
pub const default_not_found_handler = struct {
    fn not_found_handler(_: *const Context, _: void) !Respond {
        return Respond{
            .status = .@"Not Found",
            .mime = Mime.TEXT,
            .body = "404 | Not Found",
        };
    }
}.not_found_handler;

/// Initialize a router with the given routes.
pub const Router = struct {
    /// Router configuration structure.
    pub const Configuration = struct {
        not_found: TypedHandlerFn(void) = default_not_found_handler,
    };

    routes: RoutingTrie,
    configuration: Configuration,

    pub fn init(
        allocator: std.mem.Allocator,
        layers: []const Layer,
        configuration: Configuration,
    ) !Router {
        const self = Router{
            .routes = try RoutingTrie.init(allocator, layers),
            .configuration = configuration,
        };

        return self;
    }

    pub fn deinit(self: *Router, allocator: std.mem.Allocator) void {
        self.routes.deinit(allocator);
    }

    pub fn print_route_tree(self: *const Router) void {
        self.routes.print();
    }

    pub fn get_bundle_from_host(
        self: *const Router,
        path: []const u8,
        captures: []Capture,
        queries: *QueryMap,
    ) !FoundBundle {
        queries.clear();

        return try self.routes.get_bundle(path, captures, queries) orelse {
            const not_found_bundle: Bundle = .{
                .route = Route.init("").all({}, self.configuration.not_found),
                .middlewares = &.{},
            };
            return .{ .bundle = not_found_bundle, .captures = captures[0..0], .queries = queries };
        };
    }
};
