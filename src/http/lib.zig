pub const Status = @import("status.zig").Status;
pub const Method = @import("method.zig").Method;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const Mime = @import("mime.zig").Mime;
pub const Route = @import("route.zig").Route;
pub const Router = @import("router.zig").Router;
pub const Context = @import("context.zig").Context;

pub const KVPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const HTTPError = error{
    TooManyHeaders,
    ContentTooLarge,
    MalformedRequest,
};
