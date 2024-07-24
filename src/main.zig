const std = @import("std");
const builtin = @import("builtin");
const stdout = std.io.getStdOut().writer();
const zzz = @import("lib.zig");
const Server = zzz.Server;
const Router = zzz.Router;
const Request = zzz.Request;
const Response = zzz.Response;
const Mime = zzz.Mime;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = zzz.Router.init(allocator);
    try router.serve_embedded_file("/", Mime.HTML, @embedFile("sample.html"));

    var server = Server.init(.{ .allocator = allocator }, router);
    try server.bind(host, port);
    try server.listen();
}
