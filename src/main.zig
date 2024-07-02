const std = @import("std");
const builtin = @import("builtin");
const Request = @import("request.zig").Request;
const RequestLine = @import("request_line.zig").RequestLine;

const stdout = std.io.getStdOut().writer();

const ZZZ_VERSION = "0.1.0";

// Parse Requests
// Create Responses
//

pub fn main() !void {
    const port: u16 = 9862;

    try stdout.print("Starting Z3 Server...\n", .{});

    const addr = try std.net.Address.resolveIp("127.0.0.1", port);

    const server_socket = blk: {
        const socket_flags = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
        break :blk try std.posix.socket(addr.any.family, socket_flags, std.posix.IPPROTO.TCP);
    };

    {
        const socklen = addr.getOsSockLen();
        try std.posix.bind(server_socket, &addr.any, socklen);
        try std.posix.listen(server_socket, 1204);
    }
    defer std.posix.close(server_socket);

    try stdout.print("Started Z3 Server. (Port: {d})\n", .{port});

    while (true) {
        var address: std.net.Address = undefined;
        var address_len: std.posix.socklen_t = @sizeOf(std.net.Address);

        const socket = std.posix.accept(server_socket, &address.any, &address_len, std.posix.SOCK.CLOEXEC) catch continue;
        errdefer std.posix.close(socket);

        const stream: std.net.Stream = .{ .handle = socket };
        defer stream.close();

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
