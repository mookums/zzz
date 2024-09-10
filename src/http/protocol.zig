const std = @import("std");
const Job = @import("../core/lib.zig").Job;
const Capture = @import("routing_trie.zig").Capture;
const Query = @import("routing_trie.zig").Query;
const QueryMap = @import("routing_trie.zig").QueryMap;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Stage = @import("stage.zig").Stage;
const Router = @import("router.zig").Router;

pub const ProtocolConfig = struct {
    router: *Router,
    num_header_max: u32 = 32,
    /// Maximum number of Captures in a Route
    ///
    /// Default: 8
    num_captures_max: u32 = 8,
    /// Maximum number of Queries in a URL
    ///
    /// Default: 8
    num_queries_max: u32 = 8,
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
    queries: QueryMap,
    request: Request,
    response: Response,
    stage: Stage,

    pub fn init(allocator: std.mem.Allocator, config: ProtocolConfig) ProtocolData {
        var queries = QueryMap.init(allocator);
        queries.ensureTotalCapacity(config.num_queries_max) catch unreachable;

        return ProtocolData{
            .stage = .header,
            .captures = allocator.alloc(Capture, config.num_captures_max) catch unreachable,
            .queries = queries,
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
        self.queries.deinit();
        allocator.free(self.captures);
    }

    pub fn clean(self: *ProtocolData) void {
        self.response.clear();
    }
};

const testing = std.testing;

test "ProtocolData deinit" {
    var x = ProtocolData.init(testing.allocator, .{ .router = undefined });
    defer x.deinit(testing.allocator);

    try testing.expectEqual(x.stage, .header);
}
