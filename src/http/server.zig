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
const Security = @import("../core/server.zig").Security;
const zzzConfig = @import("../core/server.zig").zzzConfig;
const Provision = @import("../core/zprovision.zig").ZProvision(ProtocolData);

const RecvStatus = @import("../core/server.zig").RecvStatus;
const zzzServer = @import("../core/server.zig").Server;

/// Uses the current p.response to generate and queue up the sending
/// of a response. This is used when we already know what we want to send.
///
/// See: `route_and_respond`
fn raw_respond(p: *Provision) !RecvStatus {
    {
        const status_code: u16 = if (p.data.response.status) |status| @intFromEnum(status) else 0;
        const status_name = if (p.data.response.status) |status| @tagName(status) else "No Status";
        log.info("{d} - {d} {s}", .{ p.index, status_code, status_name });
    }

    const body = p.data.response.body orelse "";
    const header_buffer = try p.data.response.headers_into_buffer(p.buffer, @intCast(body.len));
    p.data.response.headers.clear();
    const pseudo = Pseudoslice.init(header_buffer, body, p.buffer);
    return .{ .send = pseudo };
}

fn route_and_respond(p: *Provision, router: *const Router) !RecvStatus {
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
        return .kill;
    }

    return try raw_respond(p);
}

pub fn accept_fn(provision: *Provision, p_config: ProtocolConfig, z_config: zzzConfig, backend: *Async) void {
    // HTTP doesn't need to do anything special on accept.
    // We have some generic stuff that happens but that is for zzz to do.
    // eg. Provision assigning etc.
    _ = p_config;
    _ = z_config;
    _ = backend;
    provision.data.stage = .header;
}

pub fn recv_fn(
    provision: *Provision,
    p_config: ProtocolConfig,
    z_config: zzzConfig,
    backend: *Async,
    recv_buffer: []const u8,
) RecvStatus {
    _ = z_config;
    _ = backend;

    var stage = provision.data.stage;
    const job = provision.job.recv;

    if (job.count >= p_config.size_request_max) {
        provision.data.response.set(.{
            .status = .@"Content Too Large",
            .mime = Mime.HTML,
            .body = "Request was too large",
        });

        return raw_respond(provision) catch unreachable;
    }

    switch (stage) {
        .header => {
            provision.recv_buffer.appendSlice(recv_buffer) catch unreachable;
            const header_ends = std.mem.lastIndexOf(u8, provision.recv_buffer.items, "\r\n\r\n");

            // Basically, this means we haven't finished processing the header.
            if (header_ends == null) {
                log.debug("{d} - header doesn't end in this chunk, continue", .{provision.index});
                return .recv;
            }

            log.debug("{d} - parsing header", .{provision.index});
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

                return raw_respond(provision) catch unreachable;
            };

            // Logging information about Request.
            log.info("{d} - \"{s} {s}\" {s}", .{
                provision.index,
                @tagName(provision.data.request.method),
                provision.data.request.uri,
                provision.data.request.headers.get("User-Agent") orelse "N/A",
            });

            // HTTP/1.1 REQUIRES a Host header to be present.
            const is_http_1_1 = provision.data.request.version == .@"HTTP/1.1";
            const is_host_present = provision.data.request.headers.get("Host") != null;
            if (is_http_1_1 and !is_host_present) {
                provision.data.response.set(.{
                    .status = .@"Bad Request",
                    .mime = Mime.HTML,
                    .body = "Missing \"Host\" Header",
                });

                return raw_respond(provision) catch unreachable;
            }

            if (!provision.data.request.expect_body()) {
                return route_and_respond(provision, p_config.router) catch unreachable;
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

                    return raw_respond(provision) catch unreachable;
                };
            };

            if (header_end < provision.recv_buffer.items.len) {
                const difference = provision.recv_buffer.items.len - header_end;
                if (difference == content_length) {
                    // Whole Body
                    log.debug("{d} - got whole body with header", .{provision.index});
                    const body_end = header_end + difference;
                    provision.data.request.set_body(provision.recv_buffer.items[header_end..body_end]);
                    return route_and_respond(provision, p_config.router) catch unreachable;
                } else {
                    // Partial Body
                    log.debug("{d} - got partial body with header", .{provision.index});
                    stage = .{ .body = header_end };
                    return .recv;
                }
            } else if (header_end == provision.recv_buffer.items.len) {
                // Body of length 0 probably or only got header.
                if (content_length == 0) {
                    log.debug("{d} - got body of length 0", .{provision.index});
                    // Body of Length 0.
                    provision.data.request.set_body("");
                    return route_and_respond(provision, p_config.router) catch unreachable;
                } else {
                    // Got only header.
                    log.debug("{d} - got all header aka no body", .{provision.index});
                    stage = .{ .body = header_end };
                    return .recv;
                }
            } else unreachable;
        },

        .body => |header_end| {
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

                    return raw_respond(provision) catch unreachable;
                };

                break :blk std.fmt.parseInt(u32, length_string, 10) catch {
                    provision.data.response.set(.{
                        .status = .@"Bad Request",
                        .mime = Mime.HTML,
                        .body = "",
                    });

                    return raw_respond(provision) catch unreachable;
                };
            };

            const request_length = header_end + content_length;

            // If this body will be too long, abort early.
            if (request_length > p_config.size_request_max) {
                provision.data.response.set(.{
                    .status = .@"Content Too Large",
                    .mime = Mime.HTML,
                    .body = "",
                });
                return raw_respond(provision) catch unreachable;
            }

            if (job.count >= request_length) {
                provision.data.request.set_body(provision.recv_buffer.items[header_end..request_length]);
                return route_and_respond(provision, p_config.router) catch unreachable;
            } else {
                return .recv;
            }
        },
    }
}

pub fn Server(comptime security: Security) type {
    return zzzServer(security, ProtocolData, ProtocolConfig, accept_fn, recv_fn);
}
