const std = @import("std");
const log = std.log.scoped(.@"zzz/http/router");
const assert = std.debug.assert;

const HTTPError = @import("lib.zig").HTTPError;

const _Route = @import("router/route.zig").Route;

const Capture = @import("router/routing_trie.zig").Capture;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Mime = @import("mime.zig").Mime;
const _Context = @import("context.zig").Context;

const _RoutingTrie = @import("router/routing_trie.zig").RoutingTrie;
const QueryMap = @import("router/routing_trie.zig").QueryMap;

/// Error handler type.
pub fn ErrorHandlerFn(comptime Server: type, comptime AppState: type) type {
    const Context = _Context(Server, AppState);
    return *const fn (context: *Context, err: anyerror) anyerror!void;
}

/// Create a default not found handler: send a plain text response.
pub fn default_not_found_handler(comptime Server: type, comptime AppState: type) _Route(Server, AppState).HandlerFn {
    const Context = _Context(Server, AppState);

    return struct {
        fn not_found_handler(ctx: *Context) !void {
            try ctx.respond(.{
                .status = .@"Not Found",
                .mime = Mime.TEXT,
                .body = "Not Found",
            });
        }
    }.not_found_handler;
}

/// Create a default error handler: send a plain text response with the error, if known, internal server error otherwise.
pub fn default_error_handler(comptime Server: type, comptime AppState: type) ErrorHandlerFn(Server, AppState) {
    const Context = _Context(Server, AppState);
    return struct { fn f(ctx: *Context, err: anyerror) !void {
        // Handle all default HTTP errors.
        switch (err) {
            HTTPError.ContentTooLarge => {
                try ctx.respond(.{
                    .status = .@"Content Too Large",
                    .mime = Mime.TEXT,
                    .body = "Request was too large.",
                });
            },
            HTTPError.HTTPVersionNotSupported => {
                try ctx.respond(.{
                    .status = .@"HTTP Version Not Supported",
                    .mime = Mime.HTML,
                    .body = "HTTP version not supported.",
                });
            },
            HTTPError.InvalidMethod => {
                try ctx.respond(.{
                    .status = .@"Not Implemented",
                    .mime = Mime.TEXT,
                    .body = "Not implemented.",
                });
            },
            HTTPError.LengthRequired => {
                try ctx.respond(.{
                    .status = .@"Length Required",
                    .mime = Mime.TEXT,
                    .body = "Length required.",
                });
            },
            HTTPError.MalformedRequest => {
                try ctx.respond(.{
                    .status = .@"Bad Request",
                    .mime = Mime.TEXT,
                    .body = "Malformed request.",
                });
            },
            HTTPError.MethodNotAllowed => {
                if (ctx.route) |route| {
                    add_allow_header: {
                        // We also need to add to Allow header.
                        // This uses the connection's arena to allocate 64 bytes.
                        const allowed = route.get_allowed(ctx.provision.arena.allocator()) catch break :add_allow_header;
                        ctx.provision.response.headers.put_assume_capacity("Allow", allowed);
                    }
                }
                try ctx.respond(.{
                    .status = .@"Method Not Allowed",
                    .mime = Mime.TEXT,
                    .body = "Method not allowed.",
                });
            },
            HTTPError.TooManyHeaders => {
                try ctx.respond(.{
                    .status = .@"Request Header Fields Too Large",
                    .mime = Mime.TEXT,
                    .body = "Too many headers.",
                });
            },
            HTTPError.URITooLong => {
                try ctx.respond(.{
                    .status = .@"URI Too Long",
                    .mime = Mime.TEXT,
                    .body = "URI too long.",
                });
            },
            else => {
                try ctx.respond(.{
                    .status = .@"Internal Server Error",
                    .mime = Mime.TEXT,
                    .body = "Internal server error.",
                });
            },
        }
    } }.f;
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
            error_handler: ErrorHandlerFn(Server, AppState) = default_error_handler(Server, AppState),
        };

        routes: RoutingTrie,
        not_found_route: Route,
        error_handler: ErrorHandlerFn(Server, AppState),
        state: AppState,

        pub fn init(state: AppState, comptime _routes: []const Route, comptime configuration: Configuration) Self {
            const self = Self{
                // Initialize the routing tree from the given routes.
                .routes = comptime RoutingTrie.init(_routes),
                .not_found_route = comptime Route.init("").all(configuration.not_found_handler),
                .error_handler = configuration.error_handler,
                .state = state,
            };

            return self;
        }

        pub fn get_route_from_host(self: Self, path: []const u8, captures: []Capture, queries: *QueryMap) !FoundRoute {
            return try self.routes.get_route(path, captures, queries) orelse {
                queries.clear();
                return FoundRoute{ .route = self.not_found_route, .captures = captures[0..0], .queries = queries };
            };
        }
    };
}
