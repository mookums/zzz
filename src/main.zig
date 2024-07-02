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

    try stdout.print("Starting Z3 Server...\n", .{});

    const addr = try std.net.Address.resolveIp("127.0.0.1", port);
    var server = try addr.listen(.{ .reuse_port = true, .force_nonblocking = true });
    defer server.deinit();

    try stdout.print("Started Z3 Server. (Port: {d})\n", .{port});

    while (true) {
        const connection = server.accept() catch continue;
        defer connection.stream.close();

        // Basically, the stream will be passed around from request and response.
        var stream = connection.stream;

        var buf_reader = std.io.bufferedReader(stream.reader());
        const reader = buf_reader.reader();

        var buf_writer = std.io.bufferedWriter(stream.writer());
        defer buf_writer.flush() catch unreachable;
        const writer = buf_writer.writer();

        const RequestLineParsingStage = enum {
            Method,
            Host,
            Version,
            Done,
        };
        var stage: RequestLineParsingStage = .Method;

        var no_bytes_left = false;
        parse: while (true) {
            const byte = reader.readByte() catch blk: {
                no_bytes_left = true;
                break :blk 0;
            };

            if (std.ascii.isWhitespace(byte) or no_bytes_left) {
                switch (stage) {
                    .Method => {
                        //std.debug.print("Matched Method\n", .{});
                        stage = .Host;
                    },

                    .Host => {
                        //std.debug.print("Matched Host\n", .{});
                        stage = .Version;
                    },

                    .Version => {
                        //std.debug.print("Matched Version\n", .{});
                        stage = .Done;
                        break :parse;
                    },
                    .Done => {
                        break :parse;
                    },
                }
            }
        }

        const HeaderParsingStage = enum { Name, Value };
        var stage_header: HeaderParsingStage = .Name;

        no_bytes_left = false;
        headers: while (true) {
            // Read out each line, parsing the header.
            const byte = reader.readByte() catch blk: {
                no_bytes_left = true;
                break :blk 0;
            };

            if (byte == ':' or byte == '\n' or no_bytes_left) {
                //std.debug.print("Matched Header Chunk\n", .{});
                switch (stage_header) {
                    .Name => {
                        if (byte == '\n') {
                            break :headers;
                        }
                        stage_header = .Value;
                    },

                    .Value => {
                        stage_header = .Name;
                    },
                }
            }

            if (no_bytes_left) {
                break :headers;
            }
        }

        //const file = @embedFile("./sample.html");
        writer.writeAll("HTTP/1.1 200 OK\nServer: zzz (z3)\n\r\n") catch return;
    }
}
