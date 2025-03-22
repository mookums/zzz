const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.@"zzz/http/route");
const assert = std.debug.assert;

const wrap = @import("../../core/wrapping.zig").wrap;

const Method = @import("../method.zig").Method;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const Respond = @import("../response.zig").Respond;
const Mime = @import("../mime.zig").Mime;
const Encoding = @import("../encoding.zig").Encoding;

const FsDir = @import("fs_dir.zig").FsDir;
const Context = @import("../context.zig").Context;
const Layer = @import("middleware.zig").Layer;

const MiddlewareWithData = @import("middleware.zig").MiddlewareWithData;

pub const HandlerFn = *const fn (*const Context, usize) anyerror!Respond;
pub fn TypedHandlerFn(comptime T: type) type {
    return *const fn (*const Context, T) anyerror!Respond;
}

pub const HandlerWithData = struct {
    handler: HandlerFn,
    middlewares: []const MiddlewareWithData,
    data: usize,
};

/// Structure of a server route definition.
pub const Route = struct {
    /// Defined route path.
    path: []const u8,

    /// Route Handlers.
    handlers: [9]?HandlerWithData = .{null} ** 9,

    /// Initialize a route for the given path.
    pub fn init(path: []const u8) Route {
        return Route{ .path = path };
    }

    /// Returns a comma delinated list of allowed Methods for this route. This
    /// is meant to be used as the value for the 'Allow' header in the Response.
    pub fn get_allowed(self: Route, allocator: std.mem.Allocator) ![]const u8 {
        // This gets allocated within the context of the connection's arena.
        const allowed_size = comptime blk: {
            var size = 0;
            for (std.meta.tags(Method)) |method| {
                size += @tagName(method).len + 1;
            }
            break :blk size;
        };

        const buffer = try allocator.alloc(u8, allowed_size);

        var current: []u8 = "";
        inline for (std.meta.tags(Method)) |method| {
            if (self.handlers[@intFromEnum(method)] != null) {
                current = std.fmt.bufPrint(
                    buffer,
                    "{s},{s}",
                    .{ @tagName(method), current },
                ) catch unreachable;
            }
        }

        if (current.len == 0) {
            return current;
        } else {
            return current[0 .. current.len - 1];
        }
    }

    /// Get a defined request handler for the provided method.
    /// Return NULL if no handler is defined for this method.
    pub fn get_handler(self: Route, method: Method) ?HandlerWithData {
        return self.handlers[@intFromEnum(method)];
    }

    pub fn layer(self: Route) Layer {
        return .{ .route = self };
    }

    /// Set a handler function for the provided method.
    inline fn inner_route(
        comptime method: Method,
        self: Route,
        data: anytype,
        handler_fn: TypedHandlerFn(@TypeOf(data)),
    ) Route {
        const wrapped = wrap(usize, data);
        var new_handlers = self.handlers;
        new_handlers[comptime @intFromEnum(method)] = .{
            .handler = @ptrCast(handler_fn),
            .middlewares = &.{},
            .data = wrapped,
        };

        return Route{ .path = self.path, .handlers = new_handlers };
    }

    /// Set a handler function for all methods.
    pub fn all(self: Route, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Route {
        const wrapped = wrap(usize, data);
        var new_handlers = self.handlers;

        for (&new_handlers) |*new_handler| {
            new_handler.* = .{
                .handler = @ptrCast(handler_fn),
                .middlewares = &.{},
                .data = wrapped,
            };
        }

        return Route{
            .path = self.path,
            .handlers = new_handlers,
        };
    }

    pub fn get(self: Route, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Route {
        return inner_route(.GET, self, data, handler_fn);
    }

    pub fn head(self: Route, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Route {
        return inner_route(.HEAD, self, data, handler_fn);
    }

    pub fn post(self: Route, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Route {
        return inner_route(.POST, self, data, handler_fn);
    }

    pub fn put(self: Route, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Route {
        return inner_route(.PUT, self, data, handler_fn);
    }

    pub fn delete(self: Route, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Route {
        return inner_route(.DELETE, self, data, handler_fn);
    }

    pub fn connect(self: Route, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Route {
        return inner_route(.CONNECT, self, data, handler_fn);
    }

    pub fn options(self: Route, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Route {
        return inner_route(.OPTIONS, self, data, handler_fn);
    }

    pub fn trace(self: Route, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Route {
        return inner_route(.TRACE, self, data, handler_fn);
    }

    pub fn patch(self: Route, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Route {
        return inner_route(.PATCH, self, data, handler_fn);
    }

    const ServeEmbeddedOptions = struct {
        /// If you are serving a compressed file, please
        /// set the correct encoding type.
        encoding: ?Encoding = null,
        mime: ?Mime = null,
    };

    /// Define a GET handler to serve an embedded file.
    pub fn embed_file(
        self: *const Route,
        comptime opts: ServeEmbeddedOptions,
        comptime bytes: []const u8,
    ) Route {
        return self.get({}, struct {
            fn handler_fn(ctx: *const Context, _: void) !Respond {
                const response = ctx.response;

                const cache_control: []const u8 = if (comptime builtin.mode == .Debug)
                    "no-cache"
                else
                    comptime std.fmt.comptimePrint(
                        "max-age={d}",
                        .{std.time.s_per_day * 30},
                    );

                try response.headers.put("Cache-Control", cache_control);

                // If our static item is greater than 1KB,
                // it might be more beneficial to using caching.
                if (comptime bytes.len > 1024) {
                    @setEvalBranchQuota(1_000_000);
                    const etag = comptime std.fmt.comptimePrint(
                        "\"{d}\"",
                        .{std.hash.Wyhash.hash(0, bytes)},
                    );
                    try response.headers.put("ETag", etag[0..]);

                    if (ctx.request.headers.get("If-None-Match")) |match| {
                        if (std.mem.eql(u8, etag, match)) {
                            return response.apply(.{
                                .status = .@"Not Modified",
                                .mime = Mime.HTML,
                            });
                        }
                    }
                }

                if (opts.encoding) |encoding| try response.headers.put("Content-Encoding", @tagName(encoding));
                return response.apply(.{
                    .status = .OK,
                    .mime = opts.mime orelse Mime.BIN,
                    .body = bytes,
                });
            }
        }.handler_fn);
    }
};
