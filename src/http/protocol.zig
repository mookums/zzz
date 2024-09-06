const std = @import("std");
const Job = @import("../core/lib.zig").Job;
const Capture = @import("routing_trie.zig").Capture;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Stage = @import("stage.zig").Stage;
const Router = @import("router.zig").Router;

pub const ProtocolConfig = struct {
    router: *Router,
    num_header_max: u32 = 32,
    num_captures_max: u32 = 8,
    /// Maximum size (in bytes) of the Request.
    ///
    /// Default: 2MB.
    size_request_max: u32 = 1024 * 1024 * 2,
    /// Maximum size (in bytes) of the Request URI.
    ///
    /// Default: 2KB.
    size_request_uri_max: u32 = 1024 * 2,
};

pub const ProtocolData = struct {
    captures: []Capture,
    request: Request,
    response: Response,
    stage: Stage,

    pub fn init(allocator: std.mem.Allocator, config: ProtocolConfig) ProtocolData {
        return ProtocolData{
            .stage = .header,
            .captures = allocator.alloc(Capture, config.num_captures_max) catch unreachable,
            .request = Request.init(allocator, .{
                .num_header_max = config.num_header_max,
                .size_request_max = config.size_request_max,
                .size_request_uri_max = config.size_request_uri_max,
            }) catch unreachable,
            .response = Response.init(allocator, .{
                .num_headers_max = config.num_header_max,
            }) catch unreachable,
        };
    }

    pub fn deinit(self: *ProtocolData, allocator: std.mem.Allocator) void {
        self.request.deinit();
        self.response.deinit();
        allocator.free(self.captures);
    }

    pub fn clean(self: *ProtocolData) void {
        self.response.clear();
    }
};
