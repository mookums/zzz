const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.@"zzz/http/route");
const assert = std.debug.assert;

const wrap = @import("tardy").wrap;

const Method = @import("../method.zig").Method;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const Respond = @import("../response.zig").Respond;
const Mime = @import("../mime.zig").Mime;
const Encoding = @import("../encoding.zig").Encoding;

const FsDir = @import("fs_dir.zig").FsDir;
const Context = @import("../context.zig").Context;
const Layer = @import("middleware.zig").Layer;

pub const HandlerFn = *const fn (Context, usize) anyerror!Respond;
pub fn TypedHandlerFn(comptime T: type) type {
    return *const fn (Context, T) anyerror!Respond;
}

pub const HandlerWithData = struct {
    handler: HandlerFn,
    data: usize,
};

/// Structure of a server route definition.
pub const Route = struct {
    const Self = @This();

    /// Defined route path.
    path: []const u8,

    /// Route handlers.
    handlers: [9]?HandlerWithData = [_]?HandlerWithData{null} ** 9,

    fn method_to_index(method: Method) u32 {
        return switch (method) {
            .GET => 0,
            .HEAD => 1,
            .POST => 2,
            .PUT => 3,
            .DELETE => 4,
            .CONNECT => 5,
            .OPTIONS => 6,
            .TRACE => 7,
            .PATCH => 8,
        };
    }

    /// Initialize a route for the given path.
    pub fn init(path: []const u8) Self {
        return Self{ .path = path };
    }

    /// Returns a comma delinated list of allowed Methods for this route. This
    /// is meant to be used as the value for the 'Allow' header in the Response.
    pub fn get_allowed(self: Self, allocator: std.mem.Allocator) ![]const u8 {
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
    pub fn get_handler(self: Self, method: Method) ?HandlerWithData {
        return self.handlers[method_to_index(method)];
    }

    pub fn layer(self: Self) Layer {
        return .{ .route = self };
    }

    /// Set a handler function for the provided method.
    inline fn inner_route(
        comptime method: Method,
        self: Self,
        data: anytype,
        handler_fn: TypedHandlerFn(@TypeOf(data)),
    ) Self {
        const wrapped = wrap(usize, data);
        var new_handlers = self.handlers;
        new_handlers[comptime method_to_index(method)] = .{
            .handler = @ptrCast(handler_fn),
            .data = wrapped,
        };

        return Self{ .path = self.path, .handlers = new_handlers };
    }

    /// Set a handler function for all methods.
    pub fn all(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
        const wrapped = wrap(usize, data);
        var new_handlers = self.handlers;

        for (&new_handlers) |*new_handler| {
            new_handler.* = .{
                .handler = @ptrCast(handler_fn),
                .data = wrapped,
            };
        }

        return Self{
            .path = self.path,
            .handlers = new_handlers,
        };
    }

    pub fn get(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
        return inner_route(.GET, self, data, handler_fn);
    }

    pub fn head(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
        return inner_route(.HEAD, self, handler_fn);
    }

    pub fn post(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
        return inner_route(.POST, self, data, handler_fn);
    }

    pub fn put(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
        return inner_route(.PUT, self, data, handler_fn);
    }

    pub fn delete(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
        return inner_route(.DELETE, self, data, handler_fn);
    }

    pub fn connect(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
        return inner_route(.CONNECT, self, data, handler_fn);
    }

    pub fn options(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
        return inner_route(.OPTIONS, self, data, handler_fn);
    }

    pub fn trace(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
        return inner_route(.TRACE, self, data, handler_fn);
    }

    pub fn patch(self: Self, data: anytype, handler_fn: TypedHandlerFn(@TypeOf(data))) Self {
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
        self: *const Self,
        comptime opts: ServeEmbeddedOptions,
        comptime bytes: []const u8,
    ) Self {
        return self.get({}, struct {
            fn handler_fn(ctx: *Context, _: void) !void {
                const cache_control: []const u8 = if (comptime builtin.mode == .Debug)
                    "no-cache"
                else
                    comptime std.fmt.comptimePrint(
                        "max-age={d}",
                        .{std.time.s_per_day * 30},
                    );

                ctx.response.headers.put_assume_capacity("Cache-Control", cache_control);

                // If our static item is greater than 1KB,
                // it might be more beneficial to using caching.
                if (comptime bytes.len > 1024) {
                    @setEvalBranchQuota(1_000_000);
                    const etag = comptime std.fmt.comptimePrint(
                        "\"{d}\"",
                        .{std.hash.Wyhash.hash(0, bytes)},
                    );
                    ctx.response.headers.put_assume_capacity("ETag", etag[0..]);

                    if (ctx.request.headers.get("If-None-Match")) |match| {
                        if (std.mem.eql(u8, etag, match)) {
                            return try ctx.respond(.{
                                .status = .@"Not Modified",
                                .mime = Mime.HTML,
                                .body = "",
                            });
                        }
                    }
                }

                if (opts.encoding) |encoding| {
                    ctx.response.headers.put_assume_capacity(
                        "Content-Encoding",
                        @tagName(encoding),
                    );
                }

                return try ctx.respond(.{
                    .status = .OK,
                    .mime = opts.mime,
                    .body = bytes,
                });
            }
        }.handler_fn);
    }
};
