const std = @import("std");
const assert = std.debug.assert;
const Route = @import("route.zig").Route;
const Capture = @import("routing_trie.zig").Capture;
const CapturedRoute = @import("routing_trie.zig").CapturedRoute;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Mime = @import("mime.zig").Mime;
const Context = @import("context.zig").Context;
const log = std.log.scoped(.router);

const RoutingTrie = @import("routing_trie.zig").RoutingTrie;

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
            pub fn handler_fn(request: Request, context: Context) Response {
                _ = request;
                const search_path = context.captures[0].Remaining;
                const file_path = std.fmt.allocPrint(context.allocator, "{s}/{s}", .{ dir_path, search_path }) catch {
                    return Response.init(.@"Internal Server Error", Mime.HTML, "");
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
                    return Response.init(.@"Not Found", Mime.HTML, "File not found");
                };
                defer file.close();

                const file_bytes = file.readToEndAlloc(context.allocator, 1024 * 1024 * 4) catch {
                    return Response.init(.@"Content Too Large", Mime.HTML, "");
                };

                return Response.init(.OK, mime, file_bytes);
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
            pub fn handler_fn(request: Request, _: Context) Response {
                var response = Response.init(.OK, mime, bytes);

                // We can assume that this path will be unique SINCE this is an embedded file.
                // This allows us to quickly generate a unique ETag.
                const etag = comptime std.fmt.comptimePrint("\"{d}\"", .{std.hash.Crc32.hash(path)});

                // If our static item is greater than 1KB,
                // it might be more beneficial to using caching.
                if (comptime bytes.len > 1024) {
                    response.add_header(.{
                        .key = "ETag",
                        .value = etag[0..],
                    }) catch unreachable;

                    if (request.headers.get("If-None-Match")) |match| {
                        if (std.mem.eql(u8, etag, match)) {
                            response.status = .@"Not Modified";
                            response.body = "";
                        }
                    }
                }

                return response;
            }
        }.handler_fn);

        try self.serve_route(path, route);
    }

    pub fn serve_route(self: *Router, path: []const u8, route: Route) !void {
        assert(!self.locked);
        try self.routes.add_route(path, route);
    }

    pub fn get_route_from_host(self: Router, host: []const u8, captures: []Capture) ?CapturedRoute {
        return self.routes.get_route(host, captures);
    }
};
