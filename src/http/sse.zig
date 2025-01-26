const std = @import("std");

const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;

const Provision = @import("server.zig").Provision;
const Context = @import("context.zig").Context;
const Runtime = @import("tardy").Runtime;

const SSEMessage = struct {
    id: ?[]const u8 = null,
    event: ?[]const u8 = null,
    data: ?[]const u8 = null,
    retry: ?u64 = null,
};

pub const SSE = struct {};
