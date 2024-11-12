const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.@"zzz/http/router");
const assert = std.debug.assert;

const _Route = @import("route.zig").Route;

const Capture = @import("routing_trie.zig").Capture;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Mime = @import("mime.zig").Mime;
const _Context = @import("context.zig").Context;

const _RoutingTrie = @import("routing_trie.zig").RoutingTrie;
const QueryMap = @import("routing_trie.zig").QueryMap;

const Runtime = @import("tardy").Runtime;
const Task = @import("tardy").Task;

pub fn Router(comptime Server: type) type {
    return struct {
        const Self = @This();
        const RoutingTrie = _RoutingTrie(Server);
        const FoundRoute = RoutingTrie.FoundRoute;
        const Route = _Route(Server);
        const Context = _Context(Server);
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        routes: RoutingTrie,
        /// This makes the router immutable, also making it
        /// thread-safe when shared.
        locked: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            const routes = RoutingTrie.init(allocator) catch unreachable;
            return Self{
                .allocator = allocator,
                .arena = std.heap.ArenaAllocator.init(allocator),
                .routes = routes,
                .locked = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.routes.deinit();
            self.arena.deinit();
        }

        const FileProvision = struct {
            mime: Mime,
            context: *Context,
            fd: std.posix.fd_t,
            offset: usize,
            list: std.ArrayList(u8),
            buffer: []u8,
        };

        fn open_file_task(rt: *Runtime, fd: std.posix.fd_t, provision: *FileProvision) !void {
            errdefer provision.context.respond(.{
                .status = .@"Internal Server Error",
                .mime = Mime.HTML,
                .body = "",
            }) catch unreachable;

            if (fd <= -1) {
                try provision.context.respond(.{
                    .status = .@"Not Found",
                    .mime = Mime.HTML,
                    .body = "File Not Found",
                });
                return;
            }
            provision.fd = fd;

            // TODO: If we have a If-None-Match by this point, we should fire off a stat request
            // that way we can check the last modified time and compare that with our ETag.
            // We generally avoid using the HTTP Date stuff since it can be so slow.
            //
            // If we have a matching etag, we can just respond with Not Modified.
            // If we don't then we continue doing what we normally do.
            try rt.fs.read(
                provision,
                read_file_task,
                fd,
                provision.buffer,
                0,
            );
        }

        fn read_file_task(rt: *Runtime, result: i32, provision: *FileProvision) !void {
            errdefer provision.context.respond(.{
                .status = .@"Internal Server Error",
                .mime = Mime.HTML,
                .body = "",
            }) catch unreachable;

            if (result <= 0) {
                // If we are done reading...
                try rt.fs.close(
                    provision,
                    close_file_task,
                    provision.fd,
                );
                return;
            }

            const length: usize = @intCast(result);

            try provision.list.appendSlice(provision.buffer[0..length]);

            // TODO: This needs to be a setting you pass in to the router.
            //
            //if (provision.list.items.len > 1024 * 1024 * 4) {
            //    provision.context.respond(.{
            //        .status = .@"Content Too Large",
            //        .mime = Mime.HTML,
            //        .body = "File Too Large",
            //    });
            //    return;
            //}

            provision.offset += length;

            try rt.fs.read(
                provision,
                read_file_task,
                provision.fd,
                provision.buffer,
                provision.offset,
            );
        }

        fn close_file_task(_: *Runtime, _: void, provision: *FileProvision) !void {
            try provision.context.respond(.{
                .status = .OK,
                .mime = provision.mime,
                .body = provision.list.items[0..],
            });
        }

        pub fn serve_fs_dir(self: *Self, comptime url_path: []const u8, comptime dir_path: []const u8) !void {
            assert(!self.locked);
            const arena = self.arena.allocator();

            const slice = try arena.create([]const u8);
            // Gets the real path of the directory being served.
            slice.* = try std.fs.realpathAlloc(arena, dir_path);

            const route = Route.init().get(slice, struct {
                fn handler_fn(ctx: *Context, real_dir: *const []const u8) !void {
                    // TODO: Add caching support. We shouldn't need to resend files
                    // all the time, especially if the user has gotten them before
                    // and has an ETag.

                    if (ctx.captures.len == 0) {
                        try ctx.respond(.{
                            .status = .@"Not Found",
                            .mime = Mime.HTML,
                            .body = "",
                        });
                        return;
                    }

                    const search_path = ctx.captures[0].remaining;

                    const file_path = try std.fmt.allocPrintZ(ctx.allocator, "{s}/{s}", .{ dir_path, search_path });
                    const real_path = std.fs.realpathAlloc(ctx.allocator, file_path) catch {
                        try ctx.respond(.{
                            .status = .@"Not Found",
                            .mime = Mime.HTML,
                            .body = "",
                        });
                        return;
                    };

                    if (!std.mem.startsWith(u8, real_path, real_dir.*)) {
                        try ctx.respond(.{
                            .status = .Forbidden,
                            .mime = Mime.HTML,
                            .body = "",
                        });
                        return;
                    }

                    const extension_start = std.mem.lastIndexOfScalar(u8, search_path, '.');
                    const mime: Mime = blk: {
                        if (extension_start) |start| {
                            break :blk Mime.from_extension(search_path[start..]);
                        } else {
                            break :blk Mime.BIN;
                        }
                    };

                    const provision = try ctx.allocator.create(FileProvision);

                    provision.* = .{
                        .mime = mime,
                        .context = ctx,
                        .fd = -1,
                        .offset = 0,
                        .list = std.ArrayList(u8).init(ctx.allocator),
                        .buffer = ctx.provision.buffer,
                    };

                    // We also need to support chunked encoding.
                    // It makes a lot more sense for files atleast.
                    try ctx.runtime.fs.open(
                        provision,
                        open_file_task,
                        file_path,
                    );
                }
            }.handler_fn);

            const url_with_match_all = comptime std.fmt.comptimePrint(
                "{s}/%r",
                .{std.mem.trimRight(u8, url_path, "/")},
            );

            try self.serve_route(url_with_match_all, route);
        }

        pub fn serve_embedded_file(
            self: *Self,
            comptime path: []const u8,
            comptime mime: ?Mime,
            comptime bytes: []const u8,
        ) !void {
            assert(!self.locked);
            const route = Route.init().get({}, struct {
                fn handler_fn(ctx: *Context, _: void) !void {
                    if (comptime builtin.mode == .Debug) {
                        // Don't Cache in Debug.
                        try ctx.response.headers.add(
                            "Cache-Control",
                            "no-cache",
                        );
                    } else {
                        // Cache for 30 days.
                        try ctx.response.headers.add(
                            "Cache-Control",
                            comptime std.fmt.comptimePrint("max-age={d}", .{std.time.s_per_day * 30}),
                        );
                    }

                    // If our static item is greater than 1KB,
                    // it might be more beneficial to using caching.
                    if (comptime bytes.len > 1024) {
                        @setEvalBranchQuota(1_000_000);
                        const etag = comptime std.fmt.comptimePrint("\"{d}\"", .{std.hash.Wyhash.hash(0, bytes)});
                        try ctx.response.headers.add("ETag", etag[0..]);

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

            try self.serve_route(path, route);
        }

        pub fn serve_route(self: *Self, path: []const u8, route: Route) !void {
            assert(!self.locked);
            try self.routes.add_route(path, route);
        }

        pub fn get_route_from_host(self: Self, host: []const u8, captures: []Capture, queries: *QueryMap) ?FoundRoute {
            return self.routes.get_route(host, captures, queries);
        }
    };
}
