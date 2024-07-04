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
            //std.debug.print("Thread: {d}\n", .{ctx.id});
            _ = ctx;

            switch (job) {
                .Respond => |inner| {
                    //std.debug.print("Read: {s}\n", .{inner.request});
                    inner.stream.close();
                },

                else => {},
            }
            _ = p;
        }
    }.job_handler);
    defer pool.deinit();

    try pool.start();

    const addr = try std.net.Address.resolveIp(host, port);

    std.log.debug("zzz listening...", .{});

    const server_socket = blk: {
        const socket_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
        break :blk try std.posix.socket(addr.any.family, socket_flags, std.posix.IPPROTO.TCP);
    };

    if (@hasDecl(std.posix.SO, "REUSEPORT_LB")) {
        try std.posix.setsockopt(server_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT_LB, &std.mem.toBytes(@as(c_int, 1)));
    } else if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(server_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    } else {
        try std.posix.setsockopt(server_socket, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    }

    {
        const socklen = addr.getOsSockLen();
        try std.posix.bind(server_socket, &addr.any, socklen);
    }

    try std.posix.listen(server_socket, 512);

    while (true) {
        var address: std.net.Address = undefined;
        var address_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        const socket = std.posix.accept(server_socket, &address.any, &address_len, std.posix.SOCK.CLOEXEC) catch continue;
        errdefer std.posix.close(socket);

        const stream: std.net.Stream = .{ .handle = socket };
        //std.debug.print("Opened TCP Socket!\n", .{});
        try pool.addJob(.{ .Read = .{ .stream = stream } });
    }

    try pool.abort();
}
