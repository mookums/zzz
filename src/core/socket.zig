const std = @import("std");
const builtin = @import("builtin");

pub const Socket = switch (builtin.os.tag) {
    .windows => std.os.windows.ws2_32.SOCKET,
    .freestanding => u32,
    else => std.posix.socket_t,
};
