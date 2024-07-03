const std = @import("std");
const builtin = @import("builtin");
const zzz = @import("lib.zig").zzz;

const stdout = std.io.getStdOut().writer();

const xev = @import("xev");

const Response = @import("response.zig").Response;
const Worker = @import("worker.zig").Worker;
const WorkerContext = @import("worker.zig").WorkerContext;
const WorkerPool = @import("worker.zig").WorkerPool;
const Job = @import("job.zig").Job;

pub const RequestContext = struct {
    pool: *WorkerPool,
    parent_allocator: *std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    message: std.ArrayList(u8),
};

const AcceptContext = struct {
    pool: *WorkerPool,
    parent_allocator: *std.mem.Allocator,
    work_loop: *xev.Loop,
};

pub fn tcp_accept_callback(
    ud: ?*AcceptContext,
    l: *xev.Loop,
    c: *xev.Completion,
    r: xev.AcceptError!xev.TCP,
) xev.CallbackAction {
    _ = c;
    _ = l;
    const context = ud orelse return xev.CallbackAction.rearm;
    const parent_allocator = context.parent_allocator;

    // Create the arena in the context of the parent allocator.
    var arena = std.heap.c_allocator.create(std.heap.ArenaAllocator) catch return xev.CallbackAction.rearm;
    arena.* = std.heap.ArenaAllocator.init(parent_allocator.*);
    var alloc = arena.allocator();

    var r_context = alloc.create(RequestContext) catch return xev.CallbackAction.rearm;

    // Store it in the ontext of the request.
    r_context.parent_allocator = parent_allocator;
    r_context.arena = arena;
    r_context.message = std.ArrayList(u8).init(r_context.arena.allocator());
    r_context.pool = context.pool;

    const tcp = r catch return xev.CallbackAction.rearm;
    std.debug.print("TCP Accepted!\n", .{});

    const d: *xev.Completion = r_context.arena.allocator().create(xev.Completion) catch return xev.CallbackAction.rearm;
    d.* = .{};

    const buffer: xev.ReadBuffer = .{ .slice = r_context.arena.allocator().alloc(u8, 256) catch return xev.CallbackAction.rearm };
    tcp.read(context.work_loop, d, buffer, RequestContext, r_context, tcp_read_callback);
    std.debug.print("TCP Read Entered into Queue.\n", .{});

    return xev.CallbackAction.rearm;
}

pub fn tcp_read_callback(
    ud: ?*RequestContext,
    l: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    b: xev.ReadBuffer,
    r: xev.ReadError!usize,
) xev.CallbackAction {
    _ = c;

    const context = ud orelse return xev.CallbackAction.disarm;
    const count = r catch return xev.CallbackAction.disarm;

    // Ideally, since we have an arena, we should just allocate slices for reading into.
    context.pool.addJob(Job{ .NewRead = .{ .tcp = s, .buffer = b.slice[0..count], .context = context, .loop = l } }) catch return xev.CallbackAction.disarm;

    return xev.CallbackAction.disarm;
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
        //std.debug.print("Count: {d}\n", .{count});
        //std.debug.print("Rearm Write to TCP\n", .{});
        return xev.CallbackAction.rearm;
    } else {
        //std.debug.print("Disarm Write to TCP\n", .{});
        tcp.close(l, c, void, null, xev.noopCallback);
        return xev.CallbackAction.disarm;
    }
}

pub fn tcp_close_callback(
    ud: ?*RequestContext,
    l: *xev.Loop,
    c: *xev.Completion,
    s: xev.TCP,
    r: xev.CloseError!void,
) xev.CallbackAction {
    _ = l;
    _ = c;
    _ = s;
    _ = r catch return xev.CallbackAction.disarm;
    const context = ud orelse return xev.CallbackAction.disarm;

    std.debug.print("TCP Closed!\n", .{});
    context.arena.deinit();

    const parent_alloc = context.parent_allocator;
    parent_alloc.destroy(context.arena);

    return xev.CallbackAction.disarm;
}

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    //var z3 = try zzz.init(host, port, .{ .kernel_backlog = 4096 });
    //defer z3.deinit();
    //try z3.bind();
    //try z3.listen();

    const workers = try std.heap.c_allocator.alloc(Worker, 12);

    var pool = try WorkerPool.init(std.heap.c_allocator, workers, struct {
        fn job_handler(job: Job, p: *WorkerPool, ctx: WorkerContext) void {
            std.debug.print("Thread: {d}\n", .{ctx.id});

            switch (job) {
                .Read => |read_job| {
                    const stream = read_job.stream;
                    var buf_reader = std.io.bufferedReader(stream.reader());
                    const reader = buf_reader.reader();

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

                    var no_bytes_left = false;
                    parse: while (true) {
                        const byte = reader.readByte() catch blk: {
                            no_bytes_left = true;
                            break :blk 0;
                        };

                        switch (stage) {
                            .RequestLine => |rl| {
                                if (std.ascii.isWhitespace(byte) or no_bytes_left) {
                                    switch (rl) {
                                        .Method => {
                                            //std.debug.print("Matched Method!\n", .{});
                                            stage = .{ .RequestLine = .Version };
                                        },

                                        .Version => {
                                            //std.debug.print("Matched Version!\n", .{});
                                            stage = .{ .RequestLine = .Host };
                                        },

                                        .Host => {
                                            //std.debug.print("Matched Host!\n", .{});
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

                                            //std.debug.print("Matched Header Key!\n", .{});
                                            stage = .{ .Headers = .Value };
                                        },
                                        .Value => {
                                            //std.debug.print("Matched Header Value!\n", .{});
                                            stage = .{ .Headers = .Name };
                                        },
                                    }
                                }
                            },
                        }
                    }

                    p.addJob(Job{ .Respond = .{ .stream = stream, .request = "" } }) catch return;
                },
                .Respond => |respond_job| {
                    const stream = respond_job.stream;

                    var buf_writer = std.io.bufferedWriter(stream.writer());
                    const writer = buf_writer.writer();

                    const file: []const u8 = @embedFile("sample.html");

                    var resp = Response.init(.OK);
                    resp.add_header(.{ .key = "Server", .value = "zzz (z3)" });

                    var buf = [1]u8{undefined} ** 16;
                    const len = std.fmt.formatIntBuf(&buf, file.len, 10, .lower, .{});
                    resp.add_header(.{ .key = "Content-Length", .value = buf[0..len] });

                    // We do not support keep-alive (right now).
                    resp.add_header(.{ .key = "Connection", .value = "close" });

                    resp.respond(file, writer) catch return;
                    buf_writer.flush() catch return;
                    stream.close();
                },

                .NewRead => |curr_job| {
                    std.debug.print("Read: {s}\n", .{curr_job.buffer});

                    // For now, we just close it here.
                    const d: *xev.Completion = curr_job.context.arena.allocator().create(xev.Completion) catch return;
                    d.* = .{};
                    curr_job.tcp.close(curr_job.loop, d, RequestContext, curr_job.context, tcp_close_callback);
                    std.debug.print("Submitted TCP Close into Queue.\n", .{});
                },

                else => {
                    std.debug.print("Job: {s}\n", .{@tagName(job)});
                },
            }
        }
    }.job_handler);
    defer pool.deinit();

    try pool.start();

    const addr = try std.net.Address.resolveIp(host, port);

    // NOTES FOR TOMORROW:
    //
    // You could try using libxev again...
    // Use the raw API for interacting with the socket.
    // When the socket accepts, add an accept job.
    // When the socket reads, add a read job.
    // This might help us by allowing workers do do other things while requests are in flight.
    var accept_loop = try xev.Loop.init(.{});
    defer accept_loop.deinit();

    var work_loop = try xev.Loop.init(.{});
    defer work_loop.deinit();

    var tcp = try xev.TCP.init(addr);
    try tcp.bind(addr);
    try tcp.listen(1024);
    std.log.debug("zzz listening...", .{});

    var accept_ctx: AcceptContext = .{ .pool = &pool, .parent_allocator = @constCast(&std.heap.c_allocator), .work_loop = &work_loop };

    var c: xev.Completion = .{};
    tcp.accept(&accept_loop, &c, AcceptContext, &accept_ctx, tcp_accept_callback);
    while (true) {
        // Loop for accepting requests.
        try accept_loop.run(.no_wait);
        // Loop for all the work we do on requests.
        try work_loop.run(.no_wait);
    }

    //const server_socket = blk: {
    //    const socket_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
    //    break :blk try std.posix.socket(addr.any.family, socket_flags, std.posix.IPPROTO.TCP);
    //};

    //if (@hasDecl(std.posix.SO, "REUSEPORT_LB")) {
    //    try std.posix.setsockopt(server_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
    //} else if (@hasDecl(std.posix.SO, "REUSEPORT")) {
    //    try std.posix.setsockopt(server_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    //} else {
    //    try std.posix.setsockopt(server_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    //}

    //{
    //    const socklen = addr.getOsSockLen();
    //    try std.posix.bind(server_socket, &addr.any, socklen);
    //}

    //try std.posix.listen(server_socket, 512);

    //while (true) {
    //    var address: std.net.Address = undefined;
    //    var address_len: std.posix.socklen_t = @sizeOf(std.net.Address);

    //    const socket = std.posix.accept(server_socket, &address.any, &address_len, std.posix.SOCK.CLOEXEC) catch continue;
    //    errdefer std.posix.close(socket);

    //    const stream: std.net.Stream = .{ .handle = socket };
    //    try pool.addJob(.{ .Read = .{ .stream = stream } });
    //}

    try pool.abort();
}
