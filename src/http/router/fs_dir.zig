const std = @import("std");
const log = std.log.scoped(.@"zzz/http/router");
const assert = std.debug.assert;

const Request = @import("../request.zig").Request;
const Response = @import("../response.zig").Response;
const Mime = @import("../mime.zig").Mime;
const _Context = @import("../context.zig").Context;

const Runtime = @import("tardy").Runtime;
const Stat = @import("tardy").Stat;
const Cross = @import("tardy").Cross;

pub fn FsDir(Server: type, AppState: type) type {
    return struct {
        const Context = _Context(Server, AppState);

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

            if (!Cross.fd.is_valid(fd)) {
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

            provision.response.headers.putAssumeCapacity("ETag", calc_etag);

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

            const headers = try provision.response.headers_into_buffer(
                provision.buffer,
                @intCast(stat.size),
            );
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

        pub fn handler_fn(ctx: *Context, dir_path: []const u8) !void {
            if (ctx.captures.len == 0) {
                try ctx.respond(.{
                    .status = .@"Not Found",
                    .mime = Mime.HTML,
                    .body = "",
                });
                return;
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
                    try ctx.respond(.{
                        .status = .@"Not Found",
                        .mime = Mime.HTML,
                        .body = "",
                    });
                    return;
                };
                const file_path_z = try ctx.allocator.dupeZ(u8, file_path);
                ctx.allocator.free(file_path);
                break :blk file_path_z;
            };

            // The resolved path should always start like the base directory path,
            // otherwise it means that the user is trying to access something forbidden.
            if (!std.mem.startsWith(u8, resolved_file_path, resolved_dir)) {
                defer ctx.allocator.free(resolved_file_path);
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

            try ctx.runtime.fs.open(
                provision,
                open_file_task,
                resolved_file_path,
            );
        }
    };
}
