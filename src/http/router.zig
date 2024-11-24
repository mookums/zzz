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
const Stat = @import("tardy").Stat;

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
        not_found_route: ?Route = null,
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
            request: *const Request,
            response: *Response,
            fd: std.posix.fd_t,
            file_size: u64,
            rd_offset: usize,
            current_length: usize,
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

            try rt.fs.stat(provision, stat_file_task, fd);
        }

        fn stat_file_task(rt: *Runtime, stat: Stat, provision: *FileProvision) !void {
            errdefer provision.context.respond(.{
                .status = .@"Internal Server Error",
                .mime = Mime.HTML,
                .body = "",
            }) catch unreachable;

            // Set file size.
            provision.file_size = stat.size;
            log.debug("file size: {d}", .{provision.file_size});

            // generate the etag and attach it to the response.
            var hash = std.hash.Wyhash.init(0);
            hash.update(std.mem.asBytes(&stat.size));
            if (stat.modified) |modified| {
                hash.update(std.mem.asBytes(&modified.seconds));
                hash.update(std.mem.asBytes(&modified.nanos));
            }
            const etag_hash = hash.final();

            const calc_etag = try std.fmt.allocPrint(
                provision.context.allocator,
                "\"{d}\"",
                .{etag_hash},
            );

            try provision.response.headers.put("ETag", calc_etag);

            // If we have an ETag on the request...
            if (provision.request.headers.get("If-None-Match")) |etag| {
                if (std.mem.eql(u8, etag, calc_etag)) {
                    // If the ETag matches.
                    try provision.context.respond(.{
                        .status = .@"Not Modified",
                        .mime = Mime.HTML,
                        .body = "",
                    });
                    return;
                }
            }

            provision.response.set(.{
                .status = .OK,
                .mime = provision.mime,
                .body = null,
            });

            const headers = try provision.response.headers_into_buffer(provision.buffer, stat.size);
            provision.current_length = headers.len;

            try rt.fs.read(
                provision,
                read_file_task,
                provision.fd,
                provision.buffer[provision.current_length..],
                provision.rd_offset,
            );
        }

        fn read_file_task(rt: *Runtime, result: i32, provision: *FileProvision) !void {
            errdefer {
                std.posix.close(provision.fd);
                provision.context.close() catch unreachable;
            }

            if (result <= -1) {
                log.warn("read file task failed", .{});
                std.posix.close(provision.fd);
                try provision.context.close();
                return;
            }

            const length: usize = @intCast(result);
            provision.rd_offset += length;
            provision.current_length += length;
            log.debug("current offset: {d} | fd: {}", .{ provision.rd_offset, provision.fd });

            if (provision.rd_offset >= provision.file_size or result == 0) {
                log.debug("done streaming file | rd off: {d} | f size: {d} | result: {d}", .{
                    provision.rd_offset,
                    provision.file_size,
                    result,
                });

                std.posix.close(provision.fd);
                try provision.context.send_then_recv(provision.buffer[0..provision.current_length]);
            } else {
                assert(provision.current_length <= provision.buffer.len);
                if (provision.current_length == provision.buffer.len) {
                    try provision.context.send_then(
                        provision.buffer[0..provision.current_length],
                        provision,
                        send_file_task,
                    );
                } else {
                    try rt.fs.read(
                        provision,
                        read_file_task,
                        provision.fd,
                        provision.buffer[provision.current_length..],
                        provision.rd_offset,
                    );
                }
            }
        }

        fn send_file_task(rt: *Runtime, success: bool, provision: *FileProvision) !void {
            errdefer {
                std.posix.close(provision.fd);
                provision.context.close() catch unreachable;
            }

            if (!success) {
                log.warn("send file stream failed!", .{});
                std.posix.close(provision.fd);
                return;
            }

            // reset current length
            provision.current_length = 0;

            // continue streaming..
            try rt.fs.read(
                provision,
                read_file_task,
                provision.fd,
                provision.buffer,
                provision.rd_offset,
            );
        }

        pub fn serve_fs_dir(self: *Self, comptime url_path: []const u8, comptime dir_path: []const u8) !void {
            assert(!self.locked);
            const arena = self.arena.allocator();

            const slice = try arena.create([]const u8);
            // Gets the real path of the directory being served.
            slice.* = try std.fs.realpathAlloc(arena, dir_path);

            const route = Route.init().get(slice, struct {
                fn handler_fn(ctx: *Context, real_dir: *const []const u8) !void {
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
                            if (search_path.len - start >= 0) break :blk Mime.BIN;
                            break :blk Mime.from_extension(search_path[start + 1 ..]);
                        } else {
                            break :blk Mime.BIN;
                        }
                    };

                    const provision = try ctx.allocator.create(FileProvision);

                    provision.* = .{
                        .mime = mime,
                        .context = ctx,
                        .request = ctx.request,
                        .response = ctx.response,
                        .fd = -1,
                        .file_size = 0,
                        .rd_offset = 0,
                        .current_length = 0,
                        .buffer = ctx.provision.buffer,
                    };

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
                    const cache_control: []const u8 = if (comptime builtin.mode == .Debug)
                        "no-cache"
                    else
                        comptime std.fmt.comptimePrint(
                            "max-age={d}",
                            .{std.time.s_per_day * 30},
                        );

                    try ctx.response.headers.put(
                        "Cache-Control",
                        cache_control,
                    );

                    // If our static item is greater than 1KB,
                    // it might be more beneficial to using caching.
                    if (comptime bytes.len > 1024) {
                        @setEvalBranchQuota(1_000_000);
                        const etag = comptime std.fmt.comptimePrint("\"{d}\"", .{std.hash.Wyhash.hash(0, bytes)});
                        try ctx.response.headers.put("ETag", etag[0..]);

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

        pub fn serve_not_found(self: *Self, route: Route) void {
            assert(!self.locked);
            self.not_found_route = route;
        }

        pub fn serve_route(self: *Self, path: []const u8, route: Route) !void {
            assert(!self.locked);
            try self.routes.add_route(path, route);
        }

        pub fn get_route_from_host(self: Self, path: []const u8, captures: []Capture, queries: *QueryMap) FoundRoute {
            const base_404_route = comptime Route.init().get({}, struct {
                fn not_found_handler(ctx: *Context, _: void) !void {
                    try ctx.respond(.{
                        .status = .@"Not Found",
                        .mime = Mime.HTML,
                        .body = "",
                    });
                }
            }.not_found_handler);

            return self.routes.get_route(path, captures, queries) orelse {
                queries.clearRetainingCapacity();
                if (self.not_found_route) |not_found| {
                    return FoundRoute{ .route = not_found, .captures = captures[0..0], .queries = queries };
                } else return FoundRoute{ .route = base_404_route, .captures = captures[0..0], .queries = queries };
            };
        }
    };
}
