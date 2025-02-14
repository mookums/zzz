const std = @import("std");
const assert = std.debug.assert;

const AnyCaseStringMap = @import("../core/any_case_string_map.zig").AnyCaseStringMap;
const Status = @import("lib.zig").Status;
const Mime = @import("lib.zig").Mime;
const Date = @import("lib.zig").Date;

const Stream = @import("tardy").Stream;

pub const Respond = enum {
    // When we are returning a real HTTP request, we use this.
    standard,
    // If we responded and we want to give control back to the HTTP engine.
    responded,
    // If we want the connection to close.
    close,
};

pub const Response = struct {
    status: ?Status = null,
    mime: ?Mime = null,
    body: ?[]const u8 = null,
    headers: AnyCaseStringMap,

    pub const Fields = struct {
        status: Status,
        mime: Mime,
        body: []const u8 = "",
        headers: []const [2][]const u8 = &.{},
    };

    pub fn init(allocator: std.mem.Allocator) Response {
        const headers = AnyCaseStringMap.init(allocator);
        return Response{ .headers = headers };
    }

    pub fn deinit(self: *Response) void {
        self.headers.deinit();
    }

    pub fn apply(self: *Response, into: Fields) !Respond {
        self.status = into.status;
        self.mime = into.mime;
        self.body = into.body;
        for (into.headers) |pair| try self.headers.put(pair[0], pair[1]);
        return .standard;
    }

    pub fn clear(self: *Response) void {
        self.status = null;
        self.mime = null;
        self.body = null;
        self.headers.clearRetainingCapacity();
    }

    pub fn headers_into_writer(self: *Response, writer: anytype, content_length: ?usize) !void {
        // Status Line
        const status = self.status.?;
        try writer.print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(status), @tagName(status) });

        // Headers
        try writer.writeAll("Server: zzz\r\nConnection: keep-alive\r\n");
        var iter = self.headers.iterator();
        while (iter.next()) |entry| try writer.print(
            "{s}: {s}\r\n",
            .{ entry.key_ptr.*, entry.value_ptr.* },
        );

        // Content-Type
        const mime = self.mime.?;
        const content_type = switch (mime.content_type) {
            .single => |inner| inner,
            .multiple => |content_types| content_types[0],
        };
        try writer.print("Content-Type: {s}\r\n", .{content_type});

        // Content-Length
        if (content_length) |length| try writer.print("Content-Length: {d}\r\n", .{length});

        try writer.writeAll("\r\n");
    }
};
