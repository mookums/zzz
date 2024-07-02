const std = @import("std");
const builtin = @import("builtin");
const Request = @import("request.zig").Request;
const RequestLine = @import("request_line.zig").RequestLine;

const ThreadManagers = @import("thread_manager.zig");
const StreamIterator = @import("stream_iterator.zig").StreamIterator;

const stdout = std.io.getStdOut().writer();

const ZZZ_VERSION = "0.1.0";

pub fn main() !void {
    const port: u16 = 9862;

    const addr = try std.net.Address.resolveIp("127.0.0.1", port);
    try stdout.print("Starting Z3 Server...\n", .{});
    var server = try addr.listen(.{ .reuse_port = true, .force_nonblocking = true });
    defer server.deinit();

    try stdout.print("Started Z3 Server. (Port: {d})\n", .{port});

    var threads = [_]std.Thread{undefined} ** 1;

    var pool = std.Thread.Pool{
        .allocator = std.heap.c_allocator,
        .threads = &threads,
    };
    try pool.init(.{ .allocator = std.heap.c_allocator });
    defer pool.deinit();

    while (true) {
        const connection = server.accept() catch continue;
        try pool.spawn(struct {
            fn thread_handler(conn: std.net.Server.Connection) void {
                var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
                defer arena.deinit();
                const allocator = arena.allocator();

                defer conn.stream.close();
                // Basically, the stream will be passed around from request and response.
                var stream = conn.stream;

                var buf_reader = std.io.bufferedReader(stream.reader());
                const reader = buf_reader.reader();

                var buf_writer = std.io.bufferedWriter(stream.writer());
                const writer = buf_writer.writer();

                //var iter = StreamIterator(u8, 128).init(stream);

                //if (iter.next(' ')) |method| {
                //    _ = method;
                //    //std.debug.print("method: {s}\n", .{method});
                //}

                //if (iter.next(' ')) |host| {
                //    _ = host;
                //    //std.debug.print("host: {s}\n", .{host});
                //}

                //if (iter.next('\n')) |version| {
                //    _ = version;
                //    //std.debug.print("version: {s}\n", .{version});
                //}
                //
                const RequestLineParsingStage = enum {
                    Method,
                    Host,
                    Version,
                    Done,
                };
                var stage: RequestLineParsingStage = .Method;

                const first = (reader.readUntilDelimiterOrEofAlloc(allocator, '\n', 256) catch unreachable).?;

                var start: usize = 0;
                var end: usize = 0;
                parse: for (first, 0..) |c, i| {
                    end += 1;
                    if (std.ascii.isWhitespace(c) or i == first.len - 1) {
                        switch (stage) {
                            .Method => {
                                start = end;
                                stage = .Host;
                            },

                            .Host => {
                                start = end;
                                stage = .Version;
                            },

                            .Version => {
                                start = end;
                                stage = .Done;
                                break :parse;
                            },
                            .Done => {
                                break :parse;
                            },
                        }
                    }
                }

                var headers = std.StringHashMap([]const u8).init(allocator);

                headers: while (true) {
                    // Read out each line, parsing the header.
                    const header_line_msg = reader.readUntilDelimiterAlloc(allocator, '\n', 256) catch unreachable;

                    // Breaks when we hit the body of the request.
                    // Minimum header length is 3.
                    if (header_line_msg.len < 3) {
                        break :headers;
                    }

                    if (std.mem.indexOfScalar(u8, header_line_msg, ':')) |pos| {
                        headers.put(header_line_msg[0..pos], header_line_msg[pos..]) catch unreachable;
                    }

                    //std.log.debug("Header Line --> {s}", .{header_line_msg});
                }

                const file = @embedFile("./sample.html");

                var list = std.ArrayList(u8).init(allocator);
                defer list.deinit();

                list.appendSlice("HTTP/1.0 200 OK\n") catch return;
                list.appendSlice("Server: zzz (z3) (" ++ ZZZ_VERSION ++ ")\n") catch return;
                list.appendSlice("\r\n") catch return;
                list.appendSlice(file) catch return;
                writer.writeAll(list.items) catch return;
                buf_writer.flush() catch unreachable;
            }
        }.thread_handler, .{connection});
    }
}
