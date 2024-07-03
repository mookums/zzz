const std = @import("std");
const builtin = @import("builtin");
const zzz = @import("lib.zig").zzz;

const stdout = std.io.getStdOut().writer();

const Response = @import("response.zig").Response;

const Worker = @import("worker.zig").Worker;
const WorkerContext = @import("worker.zig").WorkerContext;
const WorkerPool = @import("worker.zig").WorkerPool;
const Job = @import("job.zig").Job;

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
            _ = ctx;
            //std.debug.print("Thread: {d}\n", .{ctx.id});

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

                else => {
                    //std.debug.print("Job: {s}\n", .{@tagName(job)});
                },
            }
        }
    }.job_handler);
    defer pool.deinit();

    try pool.start();

    var addr = try std.net.Address.resolveIp(host, port);

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

    std.log.debug("zzz listening...", .{});
    try std.posix.listen(server_socket, 512);

    // NOTES FOR TOMORROW:
    //
    // You could try using libxev again...
    // Use the raw API for interacting with the socket.
    // When the socket accepts, add an accept job.
    // When the socket reads, add a read job.
    // This might help us by allowing workers do do other things while requests are in flight.

    while (true) {
        var address: std.net.Address = undefined;
        var address_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        const socket = std.posix.accept(server_socket, &address.any, &address_len, std.posix.SOCK.CLOEXEC) catch continue;
        errdefer std.posix.close(socket);

        const stream: std.net.Stream = .{ .handle = socket };
        try pool.addJob(.{ .Read = .{ .stream = stream } });
    }

    try pool.abort();
}
