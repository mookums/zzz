pub const Status = @import("status.zig").Status;
pub const Method = @import("method.zig").Method;
pub const Request = @import("request.zig").Request;
pub const Response = @import("response.zig").Response;
pub const Mime = @import("mime.zig").Mime;
pub const Date = @import("date.zig").Date;
pub const Headers = @import("../core/case_string_map.zig").CaseStringMap([]const u8);

pub const Server = @import("server.zig").Server;

pub const HTTPError = error{
    ContentTooLarge,
    HTTPVersionNotSupported,
    InvalidMethod,
    LengthRequired,
    MalformedRequest,
    MethodNotAllowed,
    TooManyHeaders,
    URITooLong,
};
