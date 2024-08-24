const std = @import("std");

const builtin = @import("builtin");
const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.@"zzz/server/http");

const Async = @import("../async/lib.zig").Async;

const Job = @import("../core/lib.zig").Job;
const Pool = @import("../core/lib.zig").Pool;
const Pseudoslice = @import("../core/lib.zig").Pseudoslice;

const HTTPError = @import("lib.zig").HTTPError;
const Request = @import("lib.zig").Request;
const Response = @import("lib.zig").Response;
const Mime = @import("lib.zig").Mime;
const Context = @import("lib.zig").Context;
const Router = @import("lib.zig").Router;

const Capture = @import("routing_trie.zig").Capture;
const ProtocolData = @import("protocol.zig").ProtocolData;
const ProtocolConfig = @import("protocol.zig").ProtocolConfig;
const zzzConfig = @import("../core/server.zig").zzzConfig;
const Provision = @import("../core/zprovision.zig").ZProvision(ProtocolData);

const zzzServer = @import("../core/server.zig").Server;

/// Uses the current p.response to generate and queue up the sending
/// of a response. This is used when we already know what we want to send.
///
/// See: `route_and_respond`
fn raw_respond(p: *Provision, z_config: zzzConfig, backend: *Async) !void {
    {
        const status_code: u16 = if (p.data.response.status) |status| @intFromEnum(status) else 0;
        const status_name = if (p.data.response.status) |status| @tagName(status) else "No Status";
        log.info("{d} - {d} {s}", .{ p.index, status_code, status_name });
    }

    const body = p.data.response.body orelse "";
    const header_buffer = try p.data.response.headers_into_buffer(p.buffer, @intCast(body.len));
    var pseudo = Pseudoslice.init(header_buffer, body, p.buffer);
    p.job = .{ .Send = .{ .slice = pseudo, .count = 0 } };
    try backend.queue_send(p, p.socket, pseudo.get(0, z_config.size_socket_buffer));
}

fn route_and_respond(p: *Provision, z_config: zzzConfig, backend: *Async, router: *const Router) !void {
    route: {
        const captured = router.get_route_from_host(p.data.request.uri, p.data.captures);
        if (captured) |c| {
            const handler = c.route.get_handler(p.data.request.method);

            if (handler) |func| {
                const context: Context = Context.init(
                    p.arena.allocator(),
                    p.data.request.uri,
                    c.captures,
                );

                func(p.data.request, &p.data.response, context);
                break :route;
            } else {
                // If we match the route but not the method.
                p.data.response.set(.{
                    .status = .@"Method Not Allowed",
                    .mime = Mime.HTML,
                    .body = "405 Method Not Allowed",
                });

                // We also need to add to Allow header.
                // This uses the connection's arena to allocate 64 bytes.
                const allowed = c.route.get_allowed(p.arena.allocator()) catch {
                    p.data.response.set(.{
                        .status = .@"Internal Server Error",
                        .mime = Mime.HTML,
                        .body = "",
                    });

                    break :route;
                };

                p.data.response.headers.add("Allow", allowed) catch {
                    p.data.response.set(.{
                        .status = .@"Internal Server Error",
                        .mime = Mime.HTML,
                        .body = "",
                    });

                    break :route;
                };

                break :route;
            }
        }

        // Didn't match any route.
        p.data.response.set(.{
            .status = .@"Not Found",
            .mime = Mime.HTML,
            .body = "404 Not Found",
        });
        break :route;
    }

    if (p.data.response.status == .Kill) {
        return error.Kill;
    }

    try raw_respond(p, z_config, backend);
}

pub fn accept_fn(provision: *Provision, p_config: ProtocolConfig, z_config: zzzConfig, backend: *Async) void {
    // HTTP doesn't need to do anything special on accept.
    // We have some generic stuff that happens but that is for zzz to do.
    // eg. Provision assigning etc.
    _ = p_config;
    _ = z_config;
    provision.data.stage = .Header;
    _ = try backend.queue_recv(provision, provision.socket, provision.buffer);
}

pub fn recv_fn(provision: *Provision, p_config: ProtocolConfig, z_config: zzzConfig, backend: *Async, read_count: u32) void {
    var stage = provision.data.stage;
    const job = provision.job.Recv;

    if (job.count >= p_config.size_request_max) {
        provision.data.response.set(.{
            .status = .@"Content Too Large",
            .mime = Mime.HTML,
            .body = "Request was too large",
        });

        raw_respond(provision, z_config, backend) catch unreachable;
        return;
    }

    switch (stage) {
        .Header => {
            provision.recv_buffer.appendSlice(provision.buffer[0..@as(usize, @intCast(read_count))]) catch unreachable;
            const header_ends = std.mem.lastIndexOf(u8, provision.recv_buffer.items, "\r\n\r\n");

            // Basically, this means we haven't finished processing the header.
            if (header_ends == null) {
                _ = backend.queue_recv(provision, provision.socket, provision.buffer) catch unreachable;
                return;
            }

            // The +4 is to account for the slice we match.
            const header_end: u32 = @intCast(header_ends.? + 4);
            provision.data.request.parse_headers(provision.recv_buffer.items[0..header_end]) catch |e| {
                switch (e) {
                    HTTPError.ContentTooLarge => {
                        provision.data.response.set(.{
                            .status = .@"Content Too Large",
                            .mime = Mime.HTML,
                            .body = "Request was too large",
                        });
                    },
                    HTTPError.TooManyHeaders => {
                        provision.data.response.set(.{
                            .status = .@"Request Header Fields Too Large",
                            .mime = Mime.HTML,
                            .body = "Too Many Headers",
                        });
                    },
                    HTTPError.MalformedRequest => {
                        provision.data.response.set(.{
                            .status = .@"Bad Request",
                            .mime = Mime.HTML,
                            .body = "Malformed Request",
                        });
                    },
                    HTTPError.URITooLong => {
                        provision.data.response.set(.{
                            .status = .@"URI Too Long",
                            .mime = Mime.HTML,
                            .body = "URI Too Long",
                        });
                    },
                    HTTPError.InvalidMethod => {
                        provision.data.response.set(.{
                            .status = .@"Not Implemented",
                            .mime = Mime.HTML,
                            .body = "Not Implemented",
                        });
                    },
                    HTTPError.HTTPVersionNotSupported => {
                        provision.data.response.set(.{
                            .status = .@"HTTP Version Not Supported",
                            .mime = Mime.HTML,
                            .body = "HTTP Version Not Supported",
                        });
                    },
                }

                raw_respond(provision, z_config, backend) catch unreachable;
                return;
            };

            // Logging information about Request.
            log.info("{d} - \"{s} {s}\" {s}", .{
                provision.index,
                @tagName(provision.data.request.method),
                provision.data.request.uri,
                provision.data.request.headers.get("User-Agent") orelse "N/A",
            });

            // HTTP/1.1 REQUIRES a Host header to be present.
            if (provision.data.request.version == .@"HTTP/1.1" and provision.data.request.headers.get("Host") == null) {
                provision.data.response.set(.{
                    .status = .@"Bad Request",
                    .mime = Mime.HTML,
                    .body = "Missing \"Host\" Header",
                });
                raw_respond(provision, z_config, backend) catch unreachable;
                return;
            }

            if (!provision.data.request.expect_body()) {
                route_and_respond(provision, z_config, backend, p_config.router) catch unreachable;
                return;
            }

            // Everything after here is a Request that is expecting a body.
            const content_length = blk: {
                const length_string = provision.data.request.headers.get("Content-Length") orelse {
                    break :blk 0;
                };

                break :blk std.fmt.parseInt(u32, length_string, 10) catch {
                    provision.data.response.set(.{
                        .status = .@"Bad Request",
                        .mime = Mime.HTML,
                        .body = "",
                    });
                    raw_respond(provision, z_config, backend) catch unreachable;
                    return;
                };
            };

            if (header_end < provision.recv_buffer.items.len) {
                const difference = provision.recv_buffer.items.len - header_end;
                if (difference == content_length) {
                    // Whole Body
                    log.debug("{d} - got whole body with header", .{provision.index});
                    const body_end = header_end + difference;
                    provision.data.request.set_body(provision.recv_buffer.items[header_end..body_end]);
                    route_and_respond(provision, z_config, backend, p_config.router) catch unreachable;
                    return;
                } else {
                    // Partial Body
                    log.debug("{d} - got partial body with header", .{provision.index});
                    stage = .{ .Body = header_end };
                    backend.queue_recv(provision, provision.socket, provision.buffer) catch unreachable;
                    return;
                }
            } else if (header_end == provision.recv_buffer.items.len) {
                // Body of length 0 probably or only got header.
                if (content_length == 0) {
                    log.debug("{d} - got body of length 0", .{provision.index});
                    // Body of Length 0.
                    provision.data.request.set_body("");
                    route_and_respond(provision, z_config, backend, p_config.router) catch unreachable;
                    return;
                } else {
                    // Got only header.
                    log.debug("{d} - got all header aka no body", .{provision.index});
                    stage = .{ .Body = header_end };
                    backend.queue_recv(provision, provision.socket, provision.buffer) catch unreachable;
                    return;
                }
            } else unreachable;
        },

        .Body => |header_end| {
            // We should ONLY be here if we expect there to be a body.
            assert(provision.data.request.expect_body());
            log.debug("{d} - body matching triggered", .{provision.index});

            const content_length = blk: {
                const length_string = provision.data.request.headers.get("Content-Length") orelse {
                    provision.data.response.set(.{
                        .status = .@"Length Required",
                        .mime = Mime.HTML,
                        .body = "",
                    });
                    raw_respond(provision, z_config, backend) catch unreachable;
                    return;
                };

                break :blk std.fmt.parseInt(u32, length_string, 10) catch {
                    provision.data.response.set(.{
                        .status = .@"Bad Request",
                        .mime = Mime.HTML,
                        .body = "",
                    });
                    raw_respond(provision, z_config, backend) catch unreachable;
                    return;
                };
            };

            // If this body will be too long, abort early.
            if (header_end + content_length > p_config.size_request_max) {
                provision.data.response.set(.{
                    .status = .@"Content Too Large",
                    .mime = Mime.HTML,
                    .body = "",
                });
                raw_respond(provision, z_config, backend) catch unreachable;
                return;
            }

            if (job.count >= content_length + header_end) {
                const end = header_end + content_length;
                provision.data.request.set_body(provision.recv_buffer.items[header_end..end]);
                route_and_respond(provision, z_config, backend, p_config.router) catch unreachable;
            } else {
                backend.queue_recv(provision, provision.socket, provision.buffer) catch unreachable;
            }
        },
    }
}

pub const Server = zzzServer(
    ProtocolData,
    ProtocolConfig,
    accept_fn,
    recv_fn,
);
