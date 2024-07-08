pub const Status = @import("status.zig").Status;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const Mime = @import("mime.zig").Mime;

pub const KVPair = struct {
    key: []const u8,
    value: []const u8,
};
