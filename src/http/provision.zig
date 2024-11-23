const std = @import("std");

const Job = @import("../core/job.zig").Job;
const Capture = @import("routing_trie.zig").Capture;
const QueryMap = @import("routing_trie.zig").QueryMap;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Stage = @import("stage.zig").Stage;
const ServerConfig = @import("server.zig").ServerConfig;

pub const Provision = struct {
    index: usize,
    job: Job,
    socket: std.posix.socket_t,
    buffer: []u8,
    recv_buffer: std.ArrayList(u8),
    arena: std.heap.ArenaAllocator,
    captures: []Capture,
    queries: QueryMap,
    request: Request,
    response: Response,
    stage: Stage,

    pub const InitContext = struct {
        allocator: std.mem.Allocator,
        config: ServerConfig,
    };

    pub fn init_hook(provisions: []Provision, ctx: InitContext) void {
        const config = ctx.config;
        for (provisions) |*provision| {
            provision.job = .empty;
            provision.socket = undefined;
            // Create Buffer
            provision.buffer = ctx.allocator.alloc(u8, config.socket_buffer_bytes) catch {
                @panic("attempting to statically allocate more memory than available. (Socket Buffer)");
            };
            // Create Recv Buffer
            provision.recv_buffer = std.ArrayList(u8).init(ctx.allocator);
            // Create the Context Arena
            provision.arena = std.heap.ArenaAllocator.init(ctx.allocator);

            provision.stage = .header;
            provision.captures = ctx.allocator.alloc(Capture, config.capture_count_max) catch unreachable;

            var queries = QueryMap.init(ctx.allocator);
            queries.ensureTotalCapacity(config.query_count_max) catch unreachable;
            provision.queries = queries;
            provision.request = Request.init(ctx.allocator, config.header_count_max) catch unreachable;
            provision.response = Response.init(ctx.allocator, config.header_count_max) catch unreachable;
        }
    }

    pub fn deinit_hook(provisions: []Provision, allocator: std.mem.Allocator) void {
        for (provisions) |*provision| {
            allocator.free(provision.buffer);
            provision.recv_buffer.deinit();
            provision.arena.deinit();
            provision.request.deinit();
            provision.response.deinit();
            provision.queries.deinit();
            allocator.free(provision.captures);
        }
    }
};
