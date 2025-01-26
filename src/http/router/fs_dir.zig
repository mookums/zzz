const std = @import("std");
const log = std.log.scoped(.@"zzz/http/router");
const assert = std.debug.assert;

const Route = @import("route.zig").Route;
const Layer = @import("middleware.zig").Layer;
const Request = @import("../request.zig").Request;
const Respond = @import("../response.zig").Respond;
const Mime = @import("../mime.zig").Mime;
const Context = @import("../context.zig").Context;

const Runtime = @import("tardy").Runtime;
const ZeroCopy = @import("tardy").ZeroCopy;
const Dir = @import("tardy").Dir;
const Stat = @import("tardy").Stat;
const Cross = @import("tardy").Cross;

pub const FsDir = struct {
    fn fs_dir_handler(ctx: *const Context, dir: Dir) !Respond {
        if (ctx.captures.len == 0) {
            return Respond{
                .status = .@"Not Found",
                .mime = Mime.HTML,
                .body = "",
            };
        }

        const BUFFER_SIZE = 1024 * 4;

        var zc = try ZeroCopy(u8).init(ctx.allocator, BUFFER_SIZE);
        var header_list = try std.ArrayListUnmanaged([2][]const u8).initCapacity(ctx.allocator, 3);

        // Resolving the requested file.
        const search_path = ctx.captures[0].remaining;
        const file_path_z = try ctx.allocator.dupeZ(u8, search_path);

        // TODO: check that the path is valid.

        const extension_start = std.mem.lastIndexOfScalar(u8, search_path, '.');
        const mime: Mime = blk: {
            if (extension_start) |start| {
                if (search_path.len - start == 0) break :blk Mime.BIN;
                break :blk Mime.from_extension(search_path[start + 1 ..]);
            } else {
                break :blk Mime.BIN;
            }
        };

        const file = dir.open_file(ctx.runtime, file_path_z, .{ .mode = .read }) catch |e| switch (e) {
            error.NotFound => {
                return Respond{
                    .status = .@"Not Found",
                    .mime = Mime.HTML,
                    .body = "",
                    .headers = try header_list.toOwnedSlice(ctx.allocator),
                };
            },
            else => return e,
        };
        const stat = try file.stat(ctx.runtime);

        var hash = std.hash.Wyhash.init(0);
        hash.update(std.mem.asBytes(&stat.size));
        if (stat.modified) |modified| {
            hash.update(std.mem.asBytes(&modified.seconds));
            hash.update(std.mem.asBytes(&modified.nanos));
        }
        const etag_hash = hash.final();

        const calc_etag = try std.fmt.allocPrint(
            ctx.allocator,
            "\"{d}\"",
            .{etag_hash},
        );

        try header_list.append(ctx.allocator, .{ "ETag", calc_etag });

        // If we have an ETag on the request...
        if (ctx.request.headers.get("If-None-Match")) |etag| {
            if (std.mem.eql(u8, etag, calc_etag)) {
                // If the ETag matches.
                return Respond{
                    .status = .@"Not Modified",
                    .mime = Mime.HTML,
                    .headers = try header_list.toOwnedSlice(ctx.allocator),
                    .body = "",
                };
            }
        }

        // TODO: Would be nice to have some sort of Stream interface.
        // Maybe like we send the header over the socket then just splice :)
        var buffer: []u8 = zc.get_write_area_assume_space(BUFFER_SIZE);
        while (true) {
            const read = try file.read_all(ctx.runtime, buffer, null);
            zc.mark_written(read);
            if (read != buffer.len) break;
            buffer = try zc.get_write_area(BUFFER_SIZE);
        }

        return Respond{
            .status = .OK,
            .mime = mime,
            .body = zc.as_slice(),
            .headers = try header_list.toOwnedSlice(ctx.allocator),
        };
    }

    /// Serve a Filesystem Directory as a Layer.
    pub fn serve(comptime url_path: []const u8, dir: Dir) Layer {
        const url_with_match_all = comptime std.fmt.comptimePrint(
            "{s}/%r",
            .{std.mem.trimRight(u8, url_path, "/")},
        );

        return Route.init(url_with_match_all).get(dir, fs_dir_handler).layer();
    }
};
