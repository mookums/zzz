const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/custom");

const Async = zzz.Async;
const AsyncError = zzz.AsyncError;
const Completion = zzz.Completion;

const CustomJob = union(enum) {
    Accept: struct { socket: std.posix.socket_t, context: *anyopaque },
    Recv: struct { socket: std.posix.socket_t, context: *anyopaque, buffer: []u8 },
    Send: struct { socket: std.posix.socket_t, context: *anyopaque, buffer: []const u8 },
};

pub const CustomAsync = struct {
    inner: *std.ArrayList(CustomJob),
    completions: [256]Completion,

    pub fn init(list: *std.ArrayList(CustomJob)) CustomAsync {
        return CustomAsync{
            .inner = list,
            .completions = [_]Completion{undefined} ** 256,
        };
    }

    pub fn queue_accept(self: *Async, ctx: *anyopaque, socket: std.posix.socket_t) AsyncError!void {
        const list: *std.ArrayList(CustomJob) = @ptrCast(@alignCast(self.runner));
        list.append(CustomJob{ .Accept = .{ .socket = socket, .context = ctx } }) catch unreachable;
    }

    pub fn queue_recv(self: *Async, ctx: *anyopaque, socket: std.posix.socket_t, buffer: []u8) AsyncError!void {
        const list: *std.ArrayList(CustomJob) = @ptrCast(@alignCast(self.runner));
        list.append(CustomJob{ .Recv = .{ .socket = socket, .context = ctx, .buffer = buffer } }) catch unreachable;
    }

    pub fn queue_send(self: *Async, ctx: *anyopaque, socket: std.posix.socket_t, buffer: []const u8) AsyncError!void {
        const list: *std.ArrayList(CustomJob) = @ptrCast(@alignCast(self.runner));
        list.append(CustomJob{ .Send = .{ .socket = socket, .context = ctx, .buffer = buffer } }) catch unreachable;
    }

    pub fn submit(self: *Async) AsyncError!void {
        _ = self;
    }

    pub fn reap(self: *Async) AsyncError![]Completion {
        const list: *std.ArrayList(CustomJob) = @ptrCast(@alignCast(self.runner));
        var reaped: usize = 0;

        while (reaped < 1) {
            var i: usize = 0;

            while (i < list.items.len and reaped < self.completions.len) : (i += 1) {
                const item = list.items[i];
                switch (item) {
                    .Accept => |inner| {
                        const com_ptr = &self.completions[reaped];

                        const res: i32 = blk: {
                            const ad = std.posix.accept(inner.socket, null, null, 0) catch |e| {
                                if (e == error.WouldBlock) {
                                    continue;
                                } else {
                                    break :blk -1;
                                }
                            };

                            break :blk @intCast(ad);
                        };

                        log.debug("Reap Accept", .{});
                        com_ptr.result = @intCast(res);
                        com_ptr.context = inner.context;
                        _ = list.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },

                    .Recv => |inner| {
                        const com_ptr = &self.completions[reaped];
                        const len: i32 = blk: {
                            const rd = std.posix.recv(inner.socket, inner.buffer, 0) catch |e| {
                                if (e == error.WouldBlock) {
                                    continue;
                                } else {
                                    break :blk -1;
                                }
                            };

                            break :blk @intCast(rd);
                        };

                        log.debug("Reap Recv", .{});
                        com_ptr.result = @intCast(len);
                        com_ptr.context = inner.context;
                        _ = list.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },

                    .Send => |inner| {
                        const com_ptr = &self.completions[reaped];
                        const len: i32 = blk: {
                            const sd = std.posix.send(inner.socket, inner.buffer, 0) catch |e| {
                                if (e == error.WouldBlock) {
                                    continue;
                                } else {
                                    break :blk -1;
                                }
                            };

                            break :blk @intCast(sd);
                        };

                        log.debug("Reap Send", .{});
                        com_ptr.result = @intCast(len);
                        com_ptr.context = inner.context;
                        _ = list.swapRemove(i);
                        i -|= 1;
                        reaped += 1;
                    },
                }
            }
        }

        return self.completions[0..reaped];
    }

    pub fn to_async(self: *CustomAsync) Async {
        return Async{
            .runner = self.inner,
            .completions = self.completions,
            ._queue_open = undefined,
            ._queue_read = undefined,
            ._queue_write = undefined,
            ._queue_accept = queue_accept,
            ._queue_recv = queue_recv,
            ._queue_send = queue_send,
            ._queue_close = undefined,
            ._submit = submit,
            ._reap = reap,
        };
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const host = "0.0.0.0";
    const port = 9862;

    var router = http.Router.init(allocator);
    defer router.deinit();

    try router.serve_route("/", http.Route.init().get(struct {
        pub fn handler_fn(_: http.Request, response: *http.Response, _: http.Context) void {
            const body =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <body>
                \\ <h1>Hello, World!</h1>
                \\ </body>
                \\ </html>
            ;

            response.set(.{
                .status = .OK,
                .mime = http.Mime.HTML,
                .body = body[0..],
            });
        }
    }.handler_fn));

    var list = std.ArrayList(CustomJob).initCapacity(allocator, 256) catch unreachable;
    defer list.deinit();

    var backend = CustomAsync.init(&list);

    var server = http.Server(.plain).init(
        .{ .allocator = allocator },
        .{ .custom = backend.to_async() },
    );
    defer server.deinit();

    try server.bind(host, port);
    try server.listen(.{ .router = &router });
}
