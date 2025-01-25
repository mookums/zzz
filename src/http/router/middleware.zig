const std = @import("std");
const log = std.log.scoped(.@"zzz/router/middleware");
const assert = std.debug.assert;

const Runtime = @import("tardy").Runtime;

const wrap = @import("tardy").wrap;
const Task = @import("tardy").TaskFn;

const Pseudoslice = @import("../../core/pseudoslice.zig").Pseudoslice;
const Server = @import("../server.zig").Server;

const Mime = @import("../mime.zig").Mime;
const Route = @import("route.zig").Route;
const HandlerWithData = @import("route.zig").HandlerWithData;
const Layer = @import("layer.zig").Layer;
const Context = @import("../context.zig").Context;

const Stage = enum { pre, post };

const PreChain = struct {
    chain: []const MiddlewareWithData,
    handler: HandlerWithData,
};

pub const Next = struct {
    const Self = @This();
    stage: Stage,
    pre_chain: PreChain,
    post_chain: []const MiddlewareWithData,
    ctx: *Context,

    fn next_middleware_task(_: *Runtime, _: void, n: *Self) !void {
        switch (n.stage) {
            .pre => {
                assert(n.pre_chain.chain.len > 0);
                const next_middleware = n.pre_chain.chain[0];
                n.pre_chain.chain = n.pre_chain.chain[1..];
                @call(.auto, next_middleware.middleware, .{ n, next_middleware.data }) catch |e| {
                    log.err("\"{s}\" [pre] middleware failed with error: {}", .{ n.ctx.provision.request.uri.?, e });
                    n.ctx.provision.response.set(.{
                        .status = .@"Internal Server Error",
                        .mime = Mime.HTML,
                        .body = "",
                    });

                    return try n.ctx.respond_without_middleware();
                };
            },
            .post => {
                assert(n.post_chain.len > 0);
                const next_middleware = n.post_chain[0];
                n.post_chain = n.post_chain[1..];
                @call(.auto, next_middleware.middleware, .{ n, next_middleware.data }) catch |e| {
                    log.err("\"{s}\" [post] middleware failed with error: {}", .{ n.ctx.provision.request.uri.?, e });
                    n.ctx.provision.response.set(.{
                        .status = .@"Internal Server Error",
                        .mime = Mime.HTML,
                        .body = "",
                    });

                    return try n.ctx.respond_without_middleware();
                };
            },
        }
    }

    pub fn run(self: *Self) !void {
        switch (self.stage) {
            .pre => {
                if (self.pre_chain.chain.len > 0) {
                    @panic("TODO");
                    //return try self.ctx.runtime.spawn(void, self, next_middleware_task);
                } else {
                    return try @call(
                        .auto,
                        self.pre_chain.handler.handler,
                        .{ self.ctx, self.pre_chain.handler.data },
                    );
                }
            },
            .post => {
                if (self.post_chain.len > 0) {
                    @panic("TODO");
                    //return try self.ctx.runtime.spawn(void, self, next_middleware_task);
                } else {
                    return try self.ctx.respond_without_middleware();
                }
            },
        }
    }
};

pub const MiddlewareFn = *const fn (*Next, usize) anyerror!void;
pub fn TypedMiddlewareFn(comptime T: type) type {
    return *const fn (*Next, T) anyerror!void;
}

pub const MiddlewareWithData = struct {
    middleware: MiddlewareFn,
    data: usize,
};

pub const Middleware = struct {
    const Self = @This();

    pre: ?MiddlewareWithData = null,
    post: ?MiddlewareWithData = null,

    pub fn init() Self {
        return .{};
    }

    pub fn before(self: Self, data: anytype, func: TypedMiddlewareFn(@TypeOf(data))) Self {
        return .{
            .pre = .{
                .middleware = @ptrCast(func),
                .data = wrap(usize, data),
            },
            .post = self.post,
        };
    }

    pub fn after(self: Self, data: anytype, func: TypedMiddlewareFn(@TypeOf(data))) Self {
        return .{
            .pre = self.pre,
            .post = .{
                .middleware = @ptrCast(func),
                .data = wrap(usize, data),
            },
        };
    }

    pub fn layer(self: Self) Layer {
        if (self.pre != null and self.post != null) {
            return .{ .pair = .{ .pre = self.pre.?, .post = self.post.? } };
        }
        if (self.pre) |p| return .{ .pre = p };
        if (self.post) |p| return .{ .post = p };
        @panic("Cannot create a layer from an empty Middleware");
    }
};
