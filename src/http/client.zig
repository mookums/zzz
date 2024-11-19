const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/client");

const create_socket = @import("../core/lib.zig").create_socket;
const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;
const Method = @import("method.zig").Method;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

const Cross = @import("tardy").Cross;
const Runtime = @import("tardy").Runtime;
const TaskFn = @import("tardy").TaskFn;

const wrap = @import("tardy").wrap;

const URLInfo = struct {
    url: []const u8,
    host: []const u8,
    host_with_port: []const u8,
    path: []const u8,
    port: u16,
};

const ParsingStyle = union(enum) {
    standard,
    ipv6: usize,
};

fn parse_url(url: []const u8) !URLInfo {
    var style: ParsingStyle = .standard;
    var path: []const u8 = "";
    var port: u16 = 80;
    var host: []const u8 = "";
    var host_with_port: []const u8 = "";
    var index: usize = 0;

    // First, check if there is a scheme.
    if (url.len >= 8) {
        if (std.mem.indexOf(u8, url[0..8], "://")) |end| {
            index += end + 3;

            if (std.mem.startsWith(u8, url[0..end], "http")) {
                if (end == 4) {
                    port = 80;
                } else if (url[4] == 's') {
                    port = 443;
                } else return error.MalformedScheme;
            }
        }
    }

    const authority_start = index;
    var authority_end = url.len;

    // Check if it is an IPv6...
    // If it is, parse it correctly.
    // IPv4 parses fine with the normal way.
    if (url[index] == '[') {
        index += 1;
        if (std.mem.indexOfScalar(u8, url[index..], ']')) |ipv6_end_idx| {
            const ipv6_end = ipv6_end_idx + index;
            index = ipv6_end;
            style = .{ .ipv6 = ipv6_end };
        } else {
            return error.MalformedIpV6;
        }
    }

    // find the start of the path, if there is one.
    if (std.mem.indexOfScalar(u8, url[index..], '/')) |path_start_idx| {
        const path_start = path_start_idx + index;
        authority_end = path_start;
        path = url[path_start..];
    } else {
        path = "/";
    }

    host_with_port = url[authority_start..authority_end];
    host = host_with_port;
    if (host_with_port.len == 0) return error.ParsingMissingHost;

    switch (style) {
        .standard => if (std.mem.indexOfScalar(u8, host_with_port, ':')) |colon_idx| {
            host = host_with_port[0..colon_idx];
            port = try std.fmt.parseInt(u16, host_with_port[colon_idx + 1 ..], 10);
        },
        .ipv6 => |ip_end| if (std.mem.indexOfScalar(u8, url[ip_end..authority_end], ':')) |colon_start_idx| {
            const colon_idx = ip_end + colon_start_idx;
            host = host_with_port[authority_start..colon_idx];
            port = try std.fmt.parseInt(u16, host_with_port[colon_idx + 1 ..], 10);
        },
    }

    return .{
        .url = url,
        .host = host,
        .host_with_port = host_with_port,
        .path = path,
        .port = port,
    };
}

const Stage = union(enum) {
    connect: struct {
        ip: []const u8,
        port: u16,
        address_list: *std.net.AddressList,
        address_index: usize,
    },
    send: usize,
    recv: union(enum) {
        header,
        body: struct {
            content_length: usize,
            header_end: usize,
        },
    },
};

const RequestContext = struct {
    allocator: std.mem.Allocator,
    info: URLInfo,
    request: *Request,
    response: *Response,
    socket: std.posix.socket_t,
    buffer: []u8,
    recv_buffer: std.ArrayListUnmanaged(u8),
    pseudo: Pseudoslice,
    stage: Stage,
    then: TaskFn(?*const Response, usize),
    then_ctx: usize,
};

fn connect_task(rt: *Runtime, socket: std.posix.socket_t, ctx: *RequestContext) !void {
    errdefer {
        log.warn("fetch failed at connect", .{});
        @call(.auto, ctx.then, .{ rt, null, ctx.then_ctx }) catch unreachable;
    }

    assert(ctx.stage == .connect);
    const stage = &ctx.stage.connect;

    // Attempts to connect to all of the returned addresses.
    if (!Cross.socket.is_valid(socket)) {
        std.posix.close(ctx.socket);
        stage.address_index += 1;

        log.debug(
            "address idx: {d} | address list len: {d}",
            .{ stage.address_index, stage.address_list.addrs.len },
        );
        if (stage.address_index >= stage.address_list.addrs.len) {
            return;
        }

        const next = stage.address_list.addrs[stage.address_index];
        ctx.socket = try create_socket(next);
        ctx.allocator.free(stage.ip);
        stage.ip = try get_ip_from_address(ctx.allocator, next);
        log.debug("next ip: {s}", .{stage.ip});

        try rt.net.connect(
            ctx,
            connect_task,
            ctx.socket,
            stage.ip,
            stage.port,
        );

        return;
    }

    stage.address_list.deinit();
    ctx.allocator.free(stage.ip);

    ctx.stage = .{ .send = 0 };
    log.debug("sending from {d} to {d}", .{ 0, ctx.buffer.len });
    const buffer = ctx.pseudo.get(0, ctx.buffer.len);
    try rt.net.send(ctx, send_task, ctx.socket, buffer);
}

fn send_task(rt: *Runtime, result: i32, ctx: *RequestContext) !void {
    errdefer {
        log.warn("fetch failed at send", .{});
        @call(.auto, ctx.then, .{ rt, null, ctx.then_ctx }) catch unreachable;
    }

    assert(ctx.stage == .send);
    const sent_length = &ctx.stage.send;

    if (result <= 0) {
        log.err("send failed!", .{});
        @call(.auto, ctx.then, .{ rt, null, ctx.then_ctx }) catch unreachable;
        try rt.net.close(ctx, close_task, ctx.socket);
        return;
    }

    const length: usize = @intCast(result);
    sent_length.* += length;

    if (sent_length.* < ctx.pseudo.len) {
        log.debug("sending from {d} to {d}", .{ sent_length.*, sent_length.* + ctx.buffer.len });
        const buffer = ctx.pseudo.get(sent_length.*, sent_length.* + ctx.buffer.len);
        try rt.net.send(ctx, send_task, ctx.socket, buffer);
    } else {
        ctx.stage = .{ .recv = .header };
        try rt.net.recv(ctx, recv_task, ctx.socket, ctx.buffer);
    }
}

fn recv_task(rt: *Runtime, result: i32, ctx: *RequestContext) !void {
    errdefer {
        log.warn("fetch failed at recv", .{});
        @call(.auto, ctx.then, .{ rt, null, ctx.then_ctx }) catch unreachable;
    }

    assert(ctx.stage == .recv);
    const stage = &ctx.stage.recv;

    if (result <= 0) {
        log.err("recv failed!", .{});
        @call(.auto, ctx.then, .{ rt, null, ctx.then_ctx }) catch unreachable;
        try rt.net.close(ctx, close_task, ctx.socket);
        return;
    }

    const length: usize = @intCast(result);
    try ctx.recv_buffer.appendSlice(ctx.allocator, ctx.buffer[0..length]);

    switch (stage.*) {
        .header => {
            const start = ctx.recv_buffer.items.len -| (length + 4);
            const header_ends = std.mem.indexOf(u8, ctx.recv_buffer.items[start..], "\r\n\r\n");

            // Basically, this means we haven't finished processing the header.
            if (header_ends == null) {
                log.debug("{d} - header doesn't end in this chunk, continue", .{99});
                try rt.net.recv(ctx, recv_task, ctx.socket, ctx.buffer);
                return;
            }

            log.debug("{d} - parsing header", .{99});
            const header_end: usize = header_ends.? + start + 4;

            try ctx.response.parse_headers(
                ctx.recv_buffer.items[0 .. header_end - 4],
                .{ .size_response_max = 1024 * 1024 },
            );
            log.debug("status: {s}", .{@tagName(ctx.response.status.?)});

            const content_length = blk: {
                const length_string = ctx.response.headers.get("Content-Length") orelse break :blk 0;
                break :blk try std.fmt.parseInt(u32, length_string, 10);
            };

            if (header_end < ctx.recv_buffer.items.len) {
                const difference = ctx.recv_buffer.items.len - header_end;
                if (difference == content_length) {
                    // Whole Body
                    log.debug("{d} - got whole body with header", .{99});
                    const body_end = header_end + difference;
                    ctx.response.set(.{
                        .body = ctx.recv_buffer.items[header_end..body_end],
                    });

                    try @call(.auto, ctx.then, .{ rt, ctx.response, ctx.then_ctx });
                    try rt.net.close(ctx, close_task, ctx.socket);
                    return;
                } else {
                    // Partial Body
                    log.debug("{d} - got partial body with header", .{99});
                    stage.* = .{ .body = .{
                        .content_length = content_length,
                        .header_end = header_end,
                    } };

                    // basically try to recv more?
                    try rt.net.recv(ctx, recv_task, ctx.socket, ctx.buffer);
                    return;
                }
            } else if (header_end == ctx.recv_buffer.items.len) {
                // Body of length 0 probably or only got header.
                if (content_length == 0) {
                    log.debug("{d} - got body of length 0", .{99});
                    // Body of Length 0.
                    ctx.response.set(.{ .body = "" });

                    try @call(.auto, ctx.then, .{ rt, ctx.response, ctx.then_ctx });
                    try rt.net.close(ctx, close_task, ctx.socket);
                    return;
                } else {
                    // Got only header.
                    log.debug("{d} - got all header aka no body", .{99});
                    stage.* = .{ .body = .{
                        .content_length = content_length,
                        .header_end = header_end,
                    } };

                    try rt.net.recv(ctx, recv_task, ctx.socket, ctx.buffer);
                    return;
                }
            } else unreachable;
        },

        .body => |*inner| {
            // We should ONLY be here if we expect there to be a body.
            log.debug("{d} - body matching", .{99});

            const request_length = inner.header_end + inner.content_length;

            // If this body will be too long, abort early.
            if (request_length > 1024 * 1024) {
                @call(.auto, ctx.then, .{ rt, null, ctx.then_ctx }) catch unreachable;
                return;
            }

            if (ctx.recv_buffer.items.len >= request_length) {
                ctx.response.set(.{
                    .body = ctx.recv_buffer.items[inner.header_end..request_length],
                });

                try @call(.auto, ctx.then, .{ rt, ctx.response, ctx.then_ctx });
                try rt.net.close(ctx, close_task, ctx.socket);
                return;
            } else {
                try rt.net.recv(ctx, recv_task, ctx.socket, ctx.buffer);
                return;
            }
        },
    }
}

fn close_task(_: *Runtime, _: void, ctx: *RequestContext) !void {
    ctx.request.deinit();
    ctx.allocator.destroy(ctx.request);
    ctx.response.deinit();
    ctx.allocator.destroy(ctx.response);
    ctx.allocator.free(ctx.buffer);
    ctx.recv_buffer.deinit(ctx.allocator);

    ctx.allocator.destroy(ctx);
}

fn get_ip_from_address(allocator: std.mem.Allocator, address: std.net.Address) ![]u8 {
    switch (address.any.family) {
        std.posix.AF.INET => {
            const bytes = @as(*const [4]u8, @ptrCast(&address.in.sa.addr));
            return try std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{
                bytes[0],
                bytes[1],
                bytes[2],
                bytes[3],
            });
        },
        std.posix.AF.INET6 => {
            const bytes = address.in6.sa.addr;
            return try std.fmt.allocPrint(
                allocator,
                "{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}",
                .{
                    @as(u16, bytes[0]) << 8 | bytes[1],
                    @as(u16, bytes[2]) << 8 | bytes[3],
                    @as(u16, bytes[4]) << 8 | bytes[5],
                    @as(u16, bytes[6]) << 8 | bytes[7],
                    @as(u16, bytes[8]) << 8 | bytes[9],
                    @as(u16, bytes[10]) << 8 | bytes[11],
                    @as(u16, bytes[12]) << 8 | bytes[13],
                    @as(u16, bytes[14]) << 8 | bytes[15],
                },
            );
        },
        else => return error.UnsupportedAddress,
    }
}

const ClientRequest = struct {
    allocator: std.mem.Allocator,
    url: []const u8,
    runtime: *Runtime,
    request: *Request,
    response: *Response,

    pub fn init(allocator: std.mem.Allocator, runtime: *Runtime, url: []const u8) !ClientRequest {
        const request = try allocator.create(Request);
        request.* = try Request.init(allocator, 32);

        const response = try allocator.create(Response);
        response.* = try Response.init(allocator, 32);

        return .{
            .allocator = allocator,
            .runtime = runtime,
            .request = request,
            .response = response,
            .url = url,
        };
    }

    pub fn add_header(self: *ClientRequest, key: []const u8, value: []const u8) !void {
        try self.request.headers.add(key, value);
    }

    pub fn add_body(self: *ClientRequest, value: []const u8) void {
        self.request.body = value;
    }

    pub fn fetch(self: *ClientRequest, then_ctx: anytype, then: TaskFn(*const Response, @TypeOf(then_ctx))) !void {
        // create an arena here that will manage this connections allocations
        // when it closes, it will free everything.
        //
        // var arena = ...

        const info = try parse_url(self.url);
        self.request.path = info.path;
        try self.request.headers.add("Host", info.host_with_port);

        const list = if (info.host[0] == '[')
            // If ipv6, strip the brackets.
            try std.net.getAddressList(self.allocator, info.host[1 .. info.host.len - 1], info.port)
        else
            try std.net.getAddressList(self.allocator, info.host, info.port);

        const first: std.net.Address = list.addrs[0];
        log.debug("First IP: {}", .{first});

        const socket = try create_socket(first);
        const ip = try get_ip_from_address(self.allocator, first);

        const buffer = try self.allocator.alloc(u8, 2048);
        const headers = try self.request.headers_into_buffer(buffer, self.request.body.len);

        // create a request context to store all data that MUST persist.
        const context = try self.allocator.create(RequestContext);
        context.* = RequestContext{
            .allocator = self.allocator,
            .info = info,
            .request = self.request,
            .response = self.response,
            .pseudo = Pseudoslice.init(headers, self.request.body, buffer),
            .stage = .{ .connect = .{
                .ip = ip,
                .port = info.port,
                .address_list = list,
                .address_index = 0,
            } },
            .socket = socket,
            .buffer = buffer,
            .recv_buffer = try std.ArrayListUnmanaged(u8).initCapacity(self.allocator, 0),
            .then = @ptrCast(then),
            .then_ctx = wrap(usize, then_ctx),
        };

        log.debug("ip: {s}", .{ip});

        // queue connect.
        try self.runtime.net.connect(
            context,
            connect_task,
            socket,
            ip,
            info.port,
        );
    }
};

const ClientOptions = struct {
    num_header_max: u32 = 32,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    options: ClientOptions,

    pub fn init(allocator: std.mem.Allocator, options: ClientOptions) Client {
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *Client) void {
        _ = self;
    }

    pub fn get(self: *Client, runtime: *Runtime, url: []const u8) !ClientRequest {
        var builder = try ClientRequest.init(self.allocator, runtime, url);
        builder.request.method = .GET;
        return builder;
    }
};

const testing = std.testing;

test "Client URL Info (Scheme with Port)" {
    const url: []const u8 = "http://localhost:9862/pathing/here";
    const info = try parse_url(url);

    try testing.expectEqualStrings(url, info.url);
    try testing.expectEqualStrings("localhost:9862", info.host_with_port);
    try testing.expectEqualStrings("localhost", info.host);
    try testing.expectEqual(9862, info.port);
    try testing.expectEqualStrings("/pathing/here", info.path);
}

test "Client URL Info (Scheme w/o Port)" {
    const url: []const u8 = "https://localhost/hi/path";
    const info = try parse_url(url);

    try testing.expectEqualStrings(url, info.url);
    try testing.expectEqualStrings("localhost", info.host_with_port);
    try testing.expectEqual(443, info.port);
    try testing.expectEqualStrings("/hi/path", info.path);
}

test "Client URL Info (No Scheme w/ Port)" {
    const url: []const u8 = "localhost:1221/hi/path";
    const info = try parse_url(url);

    try testing.expectEqualStrings(url, info.url);
    try testing.expectEqualStrings("localhost:1221", info.host_with_port);
    try testing.expectEqualStrings("localhost", info.host);
    try testing.expectEqual(1221, info.port);
    try testing.expectEqualStrings("/hi/path", info.path);
}

test "Client URL Info (IPv4)" {
    const url: []const u8 = "0.0.0.0:1234/ipv4";
    const info = try parse_url(url);

    try testing.expectEqualStrings(url, info.url);
    try testing.expectEqualStrings("0.0.0.0:1234", info.host_with_port);
    try testing.expectEqualStrings("0.0.0.0", info.host);
    try testing.expectEqual(1234, info.port);
    try testing.expectEqualStrings("/ipv4", info.path);
}

test "Client URL Info (No Scheme w/ IPv6)" {
    const url: []const u8 = "[::1]:1234/ipv4";
    const info = try parse_url(url);

    try testing.expectEqualStrings(url, info.url);
    try testing.expectEqualStrings("[::1]:1234", info.host_with_port);
    try testing.expectEqualStrings("[::1]", info.host);
    try testing.expectEqual(1234, info.port);
    try testing.expectEqualStrings("/ipv4", info.path);
}

test "Client URL Info (Scheme w/ IPv6)" {
    const url: []const u8 = "https://[::1]/ipv4";
    const info = try parse_url(url);

    try testing.expectEqualStrings(url, info.url);
    try testing.expectEqualStrings("[::1]", info.host_with_port);
    try testing.expectEqual(443, info.port);
    try testing.expectEqualStrings("/ipv4", info.path);
}
