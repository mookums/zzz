const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.@"zzz/http/router");
const assert = std.debug.assert;
const Route = @import("route.zig").Route;
const Capture = @import("routing_trie.zig").Capture;
const FoundRoute = @import("routing_trie.zig").FoundRoute;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Mime = @import("mime.zig").Mime;
const Context = @import("context.zig").Context;

const RoutingTrie = @import("routing_trie.zig").RoutingTrie;
const QueryMap = @import("routing_trie.zig").QueryMap;

pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: RoutingTrie,
    /// This makes the router immutable, also making it
    /// thread-safe when shared.
    locked: bool = false,

    pub fn init(allocator: std.mem.Allocator) Router {
        const routes = RoutingTrie.init(allocator) catch unreachable;
        return Router{ .allocator = allocator, .routes = routes, .locked = false };
    }

    pub fn deinit(self: *Router) void {
        self.routes.deinit();
    }

    pub fn serve_fs_dir(self: *Router, comptime url_path: []const u8, comptime dir_path: []const u8) !void {
        assert(!self.locked);

        const route = Route.init().get(struct {
            pub fn handler_fn(request: Request, response: *Response, context: Context) void {
                _ = request;

                const search_path = context.captures[0].remaining;
                const file_path = std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ dir_path, search_path }) catch {
                    response.set(.{
                        .status = .@"Internal Server Error",
                        .mime = Mime.HTML,
                        .body = "",
                    });
                    return;
                };

                const extension_start = std.mem.lastIndexOfScalar(u8, search_path, '.');
                const mime: Mime = blk: {
                    if (extension_start) |start| {
                        break :blk Mime.from_extension(search_path[start..]);
                    } else {
                        break :blk Mime.HTML;
                    }
                };

                const file: std.fs.File = std.fs.cwd().openFile(file_path, .{}) catch {
                    response.set(.{
                        .status = .@"Not Found",
                        .mime = Mime.HTML,
                        .body = "File Not Found",
                    });
                    return;
                };
                defer file.close();

                const file_bytes = file.readToEndAlloc(context.allocator, 1024 * 1024 * 4) catch {
                    response.set(.{
                        .status = .@"Content Too Large",
                        .mime = Mime.HTML,
                        .body = "File Too Large",
                    });
                    return;
                };

                response.set(.{
                    .status = .OK,
                    .mime = mime,
                    .body = file_bytes,
                });
            }
        }.handler_fn);

        const url_with_match_all = comptime std.fmt.comptimePrint(
            "{s}/%r",
            .{std.mem.trimRight(u8, url_path, &.{'/'})},
        );

        try self.serve_route(url_with_match_all, route);
    }

    pub fn serve_embedded_file(
        self: *Router,
        comptime path: []const u8,
        comptime mime: ?Mime,
        comptime bytes: []const u8,
    ) !void {
        assert(!self.locked);
        const route = Route.init().get(struct {
            pub fn handler_fn(ctx: *Context) void {
                if (comptime builtin.mode == .Debug) {
                    // Don't Cache in Debug.
                    ctx.response.headers.add(
                        "Cache-Control",
                        "no-cache",
                    ) catch unreachable;
                } else {
                    // Cache for 30 days.
                    ctx.response.headers.add(
                        "Cache-Control",
                        comptime std.fmt.comptimePrint("max-age={d}", .{std.time.s_per_day * 30}),
                    ) catch unreachable;
                }

                // If our static item is greater than 1KB,
                // it might be more beneficial to using caching.
                if (comptime bytes.len > 1024) {
                    @setEvalBranchQuota(1_000_000);
                    const etag = comptime std.fmt.comptimePrint("\"{d}\"", .{std.hash.Wyhash.hash(0, bytes)});
                    ctx.response.headers.add("ETag", etag[0..]) catch unreachable;

                    if (ctx.request.headers.get("If-None-Match")) |match| {
                        if (std.mem.eql(u8, etag, match)) {
                            ctx.respond(.{
                                .status = .@"Not Modified",
                                .mime = Mime.HTML,
                                .body = "",
                            });

                            return;
                        }
                    }
                }

                ctx.respond(.{
                    .status = .OK,
                    .mime = mime,
                    .body = bytes,
                });
            }
        }.handler_fn);

        try self.serve_route(path, route);
    }

    pub fn serve_route(self: *Router, path: []const u8, route: Route) !void {
        assert(!self.locked);
        try self.routes.add_route(path, route);
    }

    pub fn get_route_from_host(self: Router, host: []const u8, captures: []Capture, queries: *QueryMap) ?FoundRoute {
        return self.routes.get_route(host, captures, queries);
    }
};
