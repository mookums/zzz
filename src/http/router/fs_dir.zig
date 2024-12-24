const std = @import("std");
const log = std.log.scoped(.@"zzz/http/router");
const assert = std.debug.assert;

const Route = @import("route.zig").Route;
const Layer = @import("layer.zig").Layer;
const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const Mime = @import("../mime.zig").Mime;
const Context = @import("../context.zig").Context;

const OpenResult = @import("tardy").OpenResult;
const ReadResult = @import("tardy").ReadResult;
const SendResult = @import("tardy").SendResult;
const StatResult = @import("tardy").StatResult;

const Runtime = @import("tardy").Runtime;
const Stat = @import("tardy").Stat;
const Cross = @import("tardy").Cross;

pub const FsDir = struct {
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

    /// Serve a Filesystem Directory as a Layer.
    pub fn serve(comptime url_path: []const u8, comptime dir_path: []const u8) Layer {
        const url_with_match_all = comptime std.fmt.comptimePrint(
            "{s}/%r",
            .{std.mem.trimRight(u8, url_path, "/")},
        );

        return Route.init(url_with_match_all).get({}, struct {
            fn fs_dir_handler(ctx: *Context, _: void) !void {
                try inner_handler(ctx, dir_path);
            }
        }.fs_dir_handler).layer();
    }

    fn open_file_task(rt: *Runtime, result: OpenResult, provision: *FileProvision) !void {
        errdefer provision.context.respond(.{
            .status = .@"Internal Server Error",
            .mime = Mime.HTML,
            .body = "",
        }) catch unreachable;

        const fd = result.unwrap() catch |e| {
            log.warn("file not found | {}", .{e});
            try provision.context.respond(.{
                .status = .@"Not Found",
                .mime = Mime.HTML,
                .body = "File Not Found",
            });
            return;
        };
        provision.fd = fd;

        return try rt.fs.stat(provision, stat_file_task, fd);
    }

    fn stat_file_task(rt: *Runtime, result: StatResult, provision: *FileProvision) !void {
        errdefer provision.context.respond(.{
            .status = .@"Internal Server Error",
            .mime = Mime.HTML,
            .body = "",
        }) catch unreachable;

        const stat = result.unwrap() catch |e| {
            log.warn("stat on fd={d} failed | {}", .{ provision.fd, e });
            try provision.context.respond(.{
                .status = .@"Not Found",
                .mime = Mime.HTML,
                .body = "File Not Found",
            });
            return;
        };

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

        provision.response.headers.put_assume_capacity("ETag", calc_etag);

        // If we have an ETag on the request...
        if (provision.request.headers.get("If-None-Match")) |etag| {
            if (std.mem.eql(u8, etag, calc_etag)) {
                // If the ETag matches.
                return try provision.context.respond(.{
                    .status = .@"Not Modified",
                    .mime = Mime.HTML,
                    .body = "",
                });
            }
        }

        provision.response.set(.{
            .status = .OK,
            .mime = provision.mime,
            .body = null,
        });

        const headers = try provision.response.headers_into_buffer(
            provision.buffer,
            @intCast(stat.size),
        );
        provision.current_length = headers.len;

        return try rt.fs.read(
            provision,
            read_file_task,
            provision.fd,
            provision.buffer[provision.current_length..],
            provision.rd_offset,
        );
    }

    fn read_file_task(rt: *Runtime, result: ReadResult, provision: *FileProvision) !void {
        errdefer {
            std.posix.close(provision.fd);
            provision.context.close() catch unreachable;
        }

        const length = result.unwrap() catch |e| {
            switch (e) {
                error.EndOfFile => {
                    log.debug("done streaming file | rd off: {d} | f size: {d} ", .{
                        provision.rd_offset,
                        provision.file_size,
                    });

                    std.posix.close(provision.fd);
                    return try provision.context.send_then_recv(
                        provision.buffer[0..provision.current_length],
                    );
                },
                else => {
                    log.warn("reading on fd={d} failed | {}", .{ provision.fd, e });
                    std.posix.close(provision.fd);
                    return try provision.context.close();
                },
            }
        };

        provision.rd_offset += length;
        provision.current_length += length;
        log.debug("current offset: {d} | fd: {}", .{ provision.rd_offset, provision.fd });
        assert(provision.current_length <= provision.buffer.len);

        if (provision.current_length == provision.buffer.len) {
            return try provision.context.send_then(
                provision.buffer[0..provision.current_length],
                provision,
                send_file_task,
            );
        } else {
            return try rt.fs.read(
                provision,
                read_file_task,
                provision.fd,
                provision.buffer[provision.current_length..],
                provision.rd_offset,
            );
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
        return try rt.fs.read(
            provision,
            read_file_task,
            provision.fd,
            provision.buffer,
            provision.rd_offset,
        );
    }

    fn inner_handler(ctx: *Context, dir_path: []const u8) !void {
        if (ctx.captures.len == 0) {
            return try ctx.respond(.{
                .status = .@"Not Found",
                .mime = Mime.HTML,
                .body = "",
            });
        }

        //TODO Can we do this once and for all at initialization?
        // Resolving the base directory.
        const resolved_dir = try std.fs.path.resolve(ctx.allocator, &[_][]const u8{dir_path});
        defer ctx.allocator.free(resolved_dir);

        // Resolving the requested file.
        const search_path = ctx.captures[0].remaining;
        const resolved_file_path = blk: {
            // This appears to be leaking BUT the ctx.allocator is an
            // arena so it does get cleaned up eventually.
            const file_path = std.fs.path.resolve(
                ctx.allocator,
                &[_][]const u8{ dir_path, search_path },
            ) catch {
                return try ctx.respond(.{
                    .status = .@"Not Found",
                    .mime = Mime.HTML,
                    .body = "",
                });
            };
            const file_path_z = try ctx.allocator.dupeZ(u8, file_path);
            ctx.allocator.free(file_path);
            break :blk file_path_z;
        };

        // The resolved path should always start like the base directory path,
        // otherwise it means that the user is trying to access something forbidden.
        if (!std.mem.startsWith(u8, resolved_file_path, resolved_dir)) {
            defer ctx.allocator.free(resolved_file_path);
            return try ctx.respond(.{
                .status = .Forbidden,
                .mime = Mime.HTML,
                .body = "",
            });
        }

        const extension_start = std.mem.lastIndexOfScalar(u8, search_path, '.');
        const mime: Mime = blk: {
            if (extension_start) |start| {
                if (search_path.len - start == 0) break :blk Mime.BIN;
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
            .fd = Cross.fd.INVALID_FD,
            .file_size = 0,
            .rd_offset = 0,
            .current_length = 0,
            .buffer = ctx.provision.buffer,
        };

        return try ctx.runtime.fs.open(
            provision,
            open_file_task,
            resolved_file_path,
        );
    }
};
