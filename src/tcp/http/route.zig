const std = @import("std");
const Method = std.http.Method;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;

pub const Route = struct {
    path: []const u8,
    methods: []const Method,
    handler_fn: *const fn (request: Request) Response,
};
