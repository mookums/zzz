const std = @import("std");
const builtin = @import("builtin");
const stdout = std.io.getStdOut().writer();
const zzz = @import("lib.zig");
const Server = zzz.Server;
const Route = zzz.HTTP.Route;
const Router = zzz.HTTP.Router;
const Request = zzz.HTTP.Request;
const Response = zzz.HTTP.Response;
const Mime = zzz.HTTP.Mime;

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var router = Router.init(allocator);
    try router.serve_embedded_file("/", Mime.HTML, @embedFile("sample.html"));

    var server = Server.init(.{ .allocator = allocator }, router);
    try server.bind(host, port);
    try server.listen();
}
