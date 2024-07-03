const std = @import("std");
const xev = @import("xev");
const builtin = @import("builtin");
const zzz = @import("lib.zig").zzz;

const stdout = std.io.getStdOut().writer();

// Parse Requests
// Create Responses

const zzzContext = struct {
    const Self = @This();
    allocator: *std.mem.Allocator,
    socket: xev.TCP,
    message: std.ArrayList(u8),
};

pub fn tcp_accept_callback(
    ud: ?*std.mem.Allocator,
    l: *xev.Loop,
    c: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    const alloc = ud orelse @constCast(&std.heap.page_allocator);
    var context = alloc.create(zzzContext) catch return xev.CallbackAction.disarm;
    context.allocator = alloc;
    context.message = std.ArrayList(u8).init(alloc.*);

    const tcp = r catch return xev.CallbackAction.rearm;

    std.debug.print("TCP Accepted!\n", .{});
    const buf = xev.ReadBuffer{ .array = undefined };

    tcp.read(l, c, buf, zzzContext, context, tcp_read_callback);

    return xev.CallbackAction.disarm;
}

pub fn tcp_read_callback(
    ud: ?*zzzContext,
    l: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    b: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    const tcp = s;
    var context = ud orelse return xev.CallbackAction.disarm;
    const count = r catch return xev.CallbackAction.disarm;

    std.debug.print("Read: {s}\n", .{b.array[0..count]});
    std.debug.print("Count: {d}\n", .{count});
    context.message.appendSlice(b.array[0..count]) catch return xev.CallbackAction.disarm;

    // PARSING TIME!! <3
    if (count < 2) {
        std.debug.print("Whole: {s}", .{context.message.items});
        const RequestLineParsing = enum {
            Method,
            Host,
            Version,
        };
        const HeaderParsing = enum {
            Name,
            Value,
        };

        const ParsingStages = enum {
            RequestLine,
            Headers,
        };

        const Parsing = union(ParsingStages) {
            RequestLine: RequestLineParsing,
            Headers: HeaderParsing,
        };

        var stage: Parsing = .{ .RequestLine = .Method };

        // this is now the time to parse the request.
        parse: for (context.message.items, 0..) |byte, i| {
            const no_bytes_left = i == context.message.items.len;

            switch (stage) {
                .RequestLine => |rl| {
                    if (std.ascii.isWhitespace(byte) or no_bytes_left) {
                        switch (rl) {
                            .Method => {
                                std.debug.print("Matched Method!\n", .{});
                                stage = .{ .RequestLine = .Version };
                            },

                            .Version => {
                                std.debug.print("Matched Version!\n", .{});
                                stage = .{ .RequestLine = .Host };
                            },

                            .Host => {
                                std.debug.print("Matched Host!\n", .{});
                                stage = .{ .Headers = .Name };
                            },
                        }
                    }
                },

                .Headers => |h| {
                    if (byte == ':' or byte == '\n' or no_bytes_left) {
                        switch (h) {
                            .Name => {
                                if (byte != ':') {
                                    break :parse;
                                }

                                std.debug.print("Matched Header Key!\n", .{});
                                stage = .{ .Headers = .Value };
                            },
                            .Value => {
                                std.debug.print("Matched Header Value!\n", .{});
                                stage = .{ .Headers = .Name };
                            },
                        }
                    }
                },
            }
        }

        // We can now write out a response...
        const ret: []const u8 = "HTTP/1.1 200 OK\n\r\n";
        const slice = context.allocator.dupe(u8, ret) catch unreachable;
        const buffer = xev.WriteBuffer{ .slice = slice };

        const written = context.allocator.create(usize) catch unreachable;
        written.* = 0;

        tcp.write(l, c, buffer, usize, written, tcp_write_callback);
        return xev.CallbackAction.disarm;
    }

    return xev.CallbackAction.rearm;
}

pub fn tcp_write_callback(
    ud: ?*usize,
    l: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    b: xev.WriteBuffer,
    r: xev.WriteError!usize,
) xev.CallbackAction {
    const tcp = s;
    const count = ud.?.* + (r catch return xev.CallbackAction.disarm);
    _ = b;

    if (false) {
        ud.?.* = count;
        std.debug.print("Count: {d}\n", .{count});
        std.debug.print("Rearm Write to TCP\n", .{});
        return xev.CallbackAction.rearm;
    } else {
        std.debug.print("Disarm Write to TCP\n", .{});
        tcp.close(l, c, void, null, tcp_close_callback);
        return xev.CallbackAction.disarm;
    }
}

pub fn tcp_close_callback(
    ud: ?*void,
    l: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = ud;
    _ = l;
    _ = c;
    _ = s;
    _ = r catch return xev.CallbackAction.disarm;

    return xev.CallbackAction.disarm;
}

fn timerCallback(
    _: ?*void,
    _: *xev.Loop,
    _: *xev.Completion,
    result: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = result catch unreachable;

    std.debug.print("Timer Ran!\n", .{});
    return .disarm;
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    //var z3 = try zzz.init(host, port, .{ .kernel_backlog = 4096 });
    //defer z3.deinit();
    //try z3.bind();
    //try z3.listen();

    const addr = try std.net.Address.resolveIp(host, port);
    var tcp = try xev.TCP.init(addr);

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    try tcp.bind(addr);
    try tcp.listen(4096);

    var tc: xev.Completion = undefined;
    const timer = try xev.Timer.init();
    timer.run(&loop, &tc, 3000, void, null, timerCallback);

    const ACCEPT_COUNT = 1;
    while (true) {
        var completions: [ACCEPT_COUNT]xev.Completion = undefined;
        for (0..ACCEPT_COUNT) |i| {
            completions[i] = undefined;
        }
        for (0..ACCEPT_COUNT) |i| {
            tcp.accept(&loop, &completions[i], std.mem.Allocator, @constCast(&std.heap.page_allocator), tcp_accept_callback);
        }

        try loop.run(.until_done);
    }
}
