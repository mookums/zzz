const std = @import("std");

const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;

const Provision = @import("provision.zig").Provision;
const _Context = @import("context.zig").Context;

const TaskFn = @import("tardy").TaskFn;
const Runtime = @import("tardy").Runtime;

const SSEMessage = struct {
    id: ?[]const u8 = null,
    event: ?[]const u8 = null,
    data: ?[]const u8 = null,
    retry: ?u64 = null,
};

pub fn SSE(comptime Server: type) type {
    const Context = _Context(Server);
    return struct {
        const Self = @This();
        context: *Context,
        allocator: std.mem.Allocator,
        runtime: *Runtime,

        pub fn send(
            self: *Self,
            options: SSEMessage,
            then_context: anytype,
            then: TaskFn(bool, @TypeOf(then_context)),
        ) !void {
            var index: usize = 0;
            const buffer = self.context.provision.buffer;

            if (options.id) |id| {
                const buf = try std.fmt.bufPrint(buffer[index..], "id: {s}\n", .{id});
                index += buf.len;
            }

            if (options.event) |event| {
                const buf = try std.fmt.bufPrint(buffer[index..], "event: {s}\n", .{event});
                index += buf.len;
            }

            if (options.data) |data| {
                const buf = try std.fmt.bufPrint(buffer[index..], "data: {s}\n", .{data});
                index += buf.len;
            }

            if (options.retry) |retry| {
                const buf = try std.fmt.bufPrint(buffer[index..], "retry: {d}\n", .{retry});
                index += buf.len;
            }

            buffer[index] = '\n';
            index += 1;

            try self.context.send_then(buffer[0..index], then_context, then);
        }
    };
}
