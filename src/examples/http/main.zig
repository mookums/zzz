const std = @import("std");
const log = std.log.scoped(.@"examples/http");
const zzz = @import("zzz").Servers.TCP.HTTP;

// GENERAL NOTES:
//
//
// const zzz = @import("zzz").TCP;
// const HTTP = zzz.HTTP;
// const z3 = zzz.init();
// z3.useProtocol(.HTTP)
// z3.useProtocol({ .Custom = .{ xyz }});
// z3.server(); (versuss z3.client());
// z3.listen();
// defer z3.deinit();
//
//
// This allows us to have composable transport layers (which is the part that needs to be hardware-independent).
// The protocols can be on top of whatever transport layer, it doesn't really matter.
// Telnet is standardized on TCP but could run on UDP. Same with HTTP.
//
// This allows for powerful customization, such as having a custom transport layer (such as UART) defined for an MCU.
// This would allow you to do...
//
// const zzz = @import("zzz").Custom(.{
//  .name = "UART",
//  . whatever
//  . this
//  .that
// });
// const HTTP = zzz.HTTP;
// const z3 = zzz.init();
// z3.useProtocol(.HTTP)
// z3.useProtocol({ .Custom = .{ xyz }});
// z3.server(); (versuss z3.client());
// z3.listen(); // This would basically be an HTTP server running on top of UART. the HTTP protocol func wouldn't care.
// defer z3.deinit();

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = zzz.Router.init(allocator);
    try router.serve_embedded_file("/", zzz.Mime.HTML, @embedFile("sample.html"));

    var server = zzz.Server.init(.{ .allocator = allocator }, router);
    try server.bind(host, port);
    try server.listen();
}
