const std = @import("std");

const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;

const Provision = @import("server.zig").Provision;
const Context = @import("context.zig").Context;
const Mime = @import("mime.zig").Mime;

const Runtime = @import("tardy").Runtime;
const SecureSocket = @import("../core/secure_socket.zig").SecureSocket;

const SSEMessage = struct {
    id: ?[]const u8 = null,
    event: ?[]const u8 = null,
    data: ?[]const u8 = null,
    retry: ?u64 = null,
};

pub const SSE = struct {
    socket: SecureSocket,
    allocator: std.mem.Allocator,
    list: std.ArrayListUnmanaged(u8),
    runtime: *Runtime,

    pub fn init(ctx: *const Context) !SSE {
        try ctx.response.apply(.{
            .status = .OK,
            .mime = Mime{
                .content_type = .{ .single = "text/event-stream" },
                .extension = .{ .single = "" },
                .description = "SSE",
            },
            .headers = &.{},
        });

        var list = try std.ArrayListUnmanaged(u8).initCapacity(ctx.allocator, 0);
        errdefer list.deinit(ctx.allocator);

        try ctx.response.headers_into_writer(ctx.header_buffer.writer(), null);
        const headers = ctx.header_buffer.items;

        const sent = try ctx.socket.send_all(ctx.runtime, headers);
        if (sent != headers.len) return error.Closed;

        return .{
            .socket = ctx.socket,
            .allocator = ctx.allocator,
            .list = list,
            .runtime = ctx.runtime,
        };
    }

    pub fn send(self: *SSE, message: SSEMessage) !void {
        // just reuse the list
        defer self.list.clearRetainingCapacity();
        const writer = self.list.writer(self.allocator);

        if (message.id) |id| try writer.print("id: {s}\n", .{id});
        if (message.event) |event| try writer.print("event: {s}\n", .{event});
        if (message.data) |data| {
            var iter = std.mem.split(u8, data, "\n");
            while (iter.next()) |line| try writer.print("data: {s}\n", .{line});
        }
        if (message.retry) |retry| try writer.print("retry: {d}\n", .{retry});
        try writer.writeByte('\n');

        const sent = try self.socket.send_all(self.runtime, self.list.items);
        if (sent != self.list.items.len) return error.Closed;
    }
};
