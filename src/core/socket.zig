const std = @import("std");
const builtin = @import("builtin");

pub const Socket = switch (builtin.os.tag) {
    .freestanding => u32,
    else => std.posix.socket_t,
};
