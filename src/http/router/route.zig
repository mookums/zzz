const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.@"zzz/http/route");
const assert = std.debug.assert;

const Method = @import("../method.zig").Method;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const Mime = @import("../mime.zig").Mime;

const _FsDir = @import("fs_dir.zig").FsDir;
const _Context = @import("../context.zig").Context;

/// Structure of a server route definition.
pub fn Route(comptime Server: type, comptime AppState: type) type {
    return struct {
        const Context = _Context(Server, AppState);
        const FsDir = _FsDir(Server, AppState);

        const Self = @This();
        pub const HandlerFn = *const fn (context: *Context) anyerror!void;

        /// Defined route path.
        path: []const u8,

        /// Route handlers.
        handlers: [9]?HandlerFn = [_]?HandlerFn{null} ** 9,

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
        pub fn init(_path: []const u8) Self {
            return Self{
                .path = _path,
            };
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
                    current = std.fmt.bufPrint(buffer, "{s},{s}", .{ @tagName(method), current }) catch unreachable;
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
        pub fn get_handler(self: Self, method: Method) ?HandlerFn {
            return self.handlers[method_to_index(method)];
        }

        /// Set a new route path.
        pub fn set_path(self: Self, path: []const u8) Self {
            return Self{
                .path = path,
                .handlers = self.handlers,
            };
        }

        /// Set a handler function for the provided method.
        inline fn inner_route(
            comptime method: Method,
            self: Self,
            handler_fn: HandlerFn,
        ) Self {
            var new_handlers = self.handlers;
            new_handlers[comptime method_to_index(method)] = handler_fn;
            return Self{
                .path = self.path,
                .handlers = new_handlers,
            };
        }

        /// Set a handler function for all methods.
        pub fn all(self: Self, handler_fn: HandlerFn) Self {
            var new_handlers = self.handlers;

            for (&new_handlers) |*new_handler| {
                new_handler.* = handler_fn;
            }

            return Self{
                .path = self.path,
                .handlers = new_handlers,
            };
        }

        pub fn get(self: Self, handler_fn: HandlerFn) Self {
            return inner_route(.GET, self, handler_fn);
        }

        pub fn head(self: Self, handler_fn: HandlerFn) Self {
            return inner_route(.HEAD, self, handler_fn);
        }

        pub fn post(self: Self, handler_fn: HandlerFn) Self {
            return inner_route(.POST, self, handler_fn);
        }

        pub fn put(self: Self, handler_fn: HandlerFn) Self {
            return inner_route(.PUT, self, handler_fn);
        }

        pub fn delete(self: Self, handler_fn: HandlerFn) Self {
            return inner_route(.DELETE, self, handler_fn);
        }

        pub fn connect(self: Self, handler_fn: HandlerFn) Self {
            return inner_route(.CONNECT, self, handler_fn);
        }

        pub fn options(self: Self, handler_fn: HandlerFn) Self {
            return inner_route(.OPTIONS, self, handler_fn);
        }

        pub fn trace(self: Self, handler_fn: HandlerFn) Self {
            return inner_route(.TRACE, self, handler_fn);
        }

        pub fn patch(self: Self, handler_fn: HandlerFn) Self {
            return inner_route(.PATCH, self, handler_fn);
        }

        /// Define a GET handler to serve an embedded file.
        pub fn serve_embedded_file(
            self: *const Self,
            comptime mime: ?Mime,
            comptime bytes: []const u8,
        ) Self {
            return self.get(struct {
                fn handler_fn(ctx: *Context) !void {
                    const cache_control: []const u8 = if (comptime builtin.mode == .Debug)
                        "no-cache"
                    else
                        comptime std.fmt.comptimePrint(
                            "max-age={d}",
                            .{std.time.s_per_day * 30},
                        );

                    ctx.response.headers.putAssumeCapacity("Cache-Control", cache_control);

                    // If our static item is greater than 1KB,
                    // it might be more beneficial to using caching.
                    if (comptime bytes.len > 1024) {
                        @setEvalBranchQuota(1_000_000);
                        const etag = comptime std.fmt.comptimePrint("\"{d}\"", .{std.hash.Wyhash.hash(0, bytes)});
                        ctx.response.headers.putAssumeCapacity("ETag", etag[0..]);

                        if (ctx.request.headers.get("If-None-Match")) |match| {
                            if (std.mem.eql(u8, etag, match)) {
                                try ctx.respond(.{
                                    .status = .@"Not Modified",
                                    .mime = Mime.HTML,
                                    .body = "",
                                });

                                return;
                            }
                        }
                    }

                    try ctx.respond(.{
                        .status = .OK,
                        .mime = mime,
                        .body = bytes,
                    });
                }
            }.handler_fn);
        }

        /// Define a GET handler to serve an entire directory.
        pub fn serve_fs_dir(comptime self: *const Self, comptime dir_path: []const u8) Self {
            const url_with_match_all = comptime std.fmt.comptimePrint(
                "{s}/%r",
                .{std.mem.trimRight(u8, self.path, "/")},
            );

            return self
                // Set the new path.
                .set_path(url_with_match_all)
                // Set GET handler.
                .get(struct {
                    fn handler_fn(ctx: *Context) !void {
                        try FsDir.handler_fn(ctx, dir_path);
                    }
                }.handler_fn);
        }
    };
}
