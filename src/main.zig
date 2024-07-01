const std = @import("std");
const builtin = @import("builtin");
const Request = @import("request.zig").Request;
const RequestLine = @import("request_line.zig").RequestLine;
const stdout = std.io.getStdOut().writer();

const ZZZ_VERSION = "0.1.0";

pub fn main() !void {
    const port: u16 = 9862;

    const addr = try std.net.Address.resolveIp("127.0.0.1", port);
    try stdout.print("Starting Z3 Server...\n", .{});
    var server = try addr.listen(.{ .reuse_port = true, .force_nonblocking = true });
    defer server.deinit();

    try stdout.print("Started Z3 Server. (Port: {d})\n", .{port});

    const ThreadManager = struct {
        thread_count: usize = 0,
        max_thread_count: usize,
        lock: std.Thread.RwLock = std.Thread.RwLock{},
        const Self = @This();

        pub fn increment(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();
            self.thread_count += 1;
        }

        pub fn decrement(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();
            self.thread_count -= 1;
        }

        pub fn canSpawn(self: *Self) bool {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            return self.thread_count < self.max_thread_count;
        }
    };

    var manager = ThreadManager{ .max_thread_count = 16 };

    // Upper Event Loop.
    while (true) {
        // Ensures we can spawn.
        if (manager.canSpawn()) {
            // Use the non-blocking socket since connection is dictated by other means.
            const conn = std.net.Server.accept(&server) catch {
                continue;
            };

            try stdout.print("Connection Accepted (Addr: {any})\n", .{conn.address});
            try stdout.print("Thread Count: {d}\n", .{manager.thread_count});

            manager.increment();

            const thread = try std.Thread.spawn(.{}, struct {
                fn thread_request(connection: std.net.Server.Connection, man: *ThreadManager) !void {
                    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    //const allocator = arena.allocator();
                    defer arena.deinit();
                    defer connection.stream.close();
                    defer man.decrement();

                    // Basically, the stream will be passed around from request and response.
                    var stream = connection.stream;

                    //var request = Request.init(allocator);
                    //try request.parse(stream);

                    var buffer: [1024]u8 = [1]u8{' '} ** 1024;
                    var end: usize = 0;

                    while (true) {
                        const count = stream.read(buffer[end..]) catch {
                            return;
                        };

                        if (count == 0) {
                            break;
                        }

                        end += count;

                        // Not always a new line... This is probably helpful for parsing
                        // the headers!
                        if (std.mem.indexOfScalar(u8, buffer[0..end], '\n')) |pos| {
                            var request_line = RequestLine.init(buffer[0..pos]);
                            try request_line.parse();
                            break;
                        }
                    }

                    const file = @embedFile("./sample.html");
                    stream.writeAll("HTTP/1.0 200 OK\n") catch return;
                    stream.writeAll("Server: zzz (z3) (" ++ ZZZ_VERSION ++ ")\n") catch return;
                    stream.writeAll("\r\n") catch return;
                    stream.writeAll(file) catch return;
                }
            }.thread_request, .{ conn, &manager });
            thread.detach();
        }
    }
}
