const std = @import("std");
pub const Job = @import("job.zig").Job;
pub const ZeroCopyBuffer = @import("zc_buffer.zig").ZeroCopyBuffer;
pub const Pseudoslice = @import("pseudoslice.zig").Pseudoslice;

pub fn create_socket(addr: std.net.Address) !std.posix.socket_t {
    const protocol: u32 = if (addr.any.family == std.posix.AF.UNIX)
        0
    else
        std.posix.IPPROTO.TCP;

    const socket = try std.posix.socket(
        addr.any.family,
        std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC | std.posix.SOCK.NONBLOCK,
        protocol,
    );

    if (@hasDecl(std.posix.SO, "REUSEPORT_LB")) {
        try std.posix.setsockopt(
            socket,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEPORT_LB,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    } else if (@hasDecl(std.posix.SO, "REUSEPORT")) {
        try std.posix.setsockopt(
            socket,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEPORT,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    } else {
        try std.posix.setsockopt(
            socket,
            std.posix.SOL.SOCKET,
            std.posix.SO.REUSEADDR,
            &std.mem.toBytes(@as(c_int, 1)),
        );
    }

    return socket;
}
