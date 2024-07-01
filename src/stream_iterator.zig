const std = @import("std");

// This will work...
pub fn StreamIterator(comptime T: type, comptime buffer_size: comptime_int) type {
    return struct {
        buffer: [buffer_size]u8 = [_]u8{0} ** buffer_size,
        stream: std.net.Stream,
        start: usize,
        end: usize,
        eof: bool = false,
        const Self = @This();

        pub fn init(stream: std.net.Stream) Self {
            return Self{
                .start = 0,
                .end = 0,
                .stream = stream,
            };
        }

        pub fn next(self: *Self, delimiter: T) ?[]T {
            // Loop pretty much forever.
            var continue_search = false;
            while (true) {
                // TODO: Add Error Handling.
                // TODO: Make it a circular buffer?
                if (continue_search) {
                    var buffer_stream = std.io.fixedBufferStream(self.buffer[self.end..]);
                    _ = self.stream.reader().streamUntilDelimiter(buffer_stream.writer(), '\n', self.buffer.len - self.end) catch {
                        self.eof = true;
                        return self.buffer[self.start..self.end];
                    };

                    std.debug.print("Written: {s}\n", .{buffer_stream.getWritten()});
                    const count = buffer_stream.getWritten().len;

                    if (count == 0) {
                        // This means that we we did not find anything on the next line.
                        return null;
                    }

                    self.end += count;
                    self.buffer[self.end] = '\n';
                    self.end += 1;
                }

                if (std.mem.indexOfScalar(T, self.buffer[self.start..self.end], delimiter)) |pos| {
                    const return_slice = self.buffer[self.start .. self.start + pos];
                    self.start = self.start + pos + 1;
                    return return_slice;
                } else {
                    continue_search = true;
                }
            }
        }
    };
}
