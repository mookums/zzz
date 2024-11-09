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

    pub fn init_hook(provisions: []Provision, config: ServerConfig) void {
        for (provisions) |*provision| {
            provision.job = .empty;
            provision.socket = undefined;
            // Create Buffer
            provision.buffer = config.allocator.alloc(u8, config.size_socket_buffer) catch {
                @panic("attempting to statically allocate more memory than available. (Socket Buffer)");
            };
            // Create Recv Buffer
            provision.recv_buffer = std.ArrayList(u8).init(config.allocator);
            // Create the Context Arena
            provision.arena = std.heap.ArenaAllocator.init(config.allocator);

            provision.stage = .header;
            provision.captures = config.allocator.alloc(Capture, config.num_captures_max) catch unreachable;

            var queries = QueryMap.init(config.allocator);
            queries.ensureTotalCapacity(config.num_queries_max) catch unreachable;
            provision.queries = queries;
            provision.request = Request.init(config.allocator, config.num_header_max) catch unreachable;
            provision.response = Response.init(config.allocator, config.num_header_max) catch unreachable;
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
