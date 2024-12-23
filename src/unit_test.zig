const std = @import("std");
const testing = std.testing;

pub const Core = @import("./core/lib.zig");
pub const HTTP = @import("./http/lib.zig");

test "zzz unit tests" {
    // Core
    testing.refAllDecls(@import("./core/case_string_map.zig"));
    testing.refAllDecls(@import("./core/job.zig"));
    testing.refAllDecls(@import("./core/pseudoslice.zig"));
    testing.refAllDecls(@import("./core/zc_buffer.zig"));

    // HTTP
    testing.refAllDecls(@import("./http/context.zig"));
    testing.refAllDecls(@import("./http/date.zig"));
    testing.refAllDecls(@import("./http/method.zig"));
    testing.refAllDecls(@import("./http/mime.zig"));
    testing.refAllDecls(@import("./http/provision.zig"));
    testing.refAllDecls(@import("./http/request.zig"));
    testing.refAllDecls(@import("./http/response.zig"));
    testing.refAllDecls(@import("./http/server.zig"));
    testing.refAllDecls(@import("./http/sse.zig"));
    testing.refAllDecls(@import("./http/status.zig"));

    // Router
    testing.refAllDecls(@import("./http/router.zig"));
    testing.refAllDecls(@import("./http/router/route.zig"));
    testing.refAllDecls(@import("./http/router/routing_trie.zig"));

    // TLS
    testing.refAllDecls(@import("./tls/bear.zig"));
}
