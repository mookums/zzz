const std = @import("std");

const ZeroCopy = @import("tardy").ZeroCopy;

const Job = @import("../core/job.zig").Job;
const Capture = @import("router/routing_trie.zig").Capture;
const QueryMap = @import("router/routing_trie.zig").QueryMap;
const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const Context = @import("context.zig").Context;
const ServerConfig = @import("server.zig").ServerConfig;

const Runtime = @import("tardy").Runtime;

pub const Stage = union(enum) {
    header,
    body: usize,
};

pub const Provision = struct {
    initalized: bool = false,
    index: usize,
    recv_buffer: ZeroCopy(u8),
    buffer: []u8,
    arena: std.heap.ArenaAllocator,
    captures: []Capture,
    queries: QueryMap,
    request: Request,
    response: Response,

    pub const InitContext = struct {
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        config: ServerConfig,
    };

    pub fn init_hook(provisions: []Provision, ctx: InitContext) void {
        const config = ctx.config;
        for (provisions) |*provision| {
            provision.job = .empty;
            // Create Recv Buffer
            provision.recv_buffer = ZeroCopy(u8).init(ctx.allocator, config.socket_buffer_bytes) catch {
                @panic("attempting to statically allocate more memory than available. (ZeroCopyBuffer)");
            };
            // Create the Context Arena
            provision.arena = std.heap.ArenaAllocator.init(ctx.allocator);

            provision.captures = ctx.allocator.alloc(Capture, config.capture_count_max) catch {
                @panic("attempting to statically allocate more memory than available. (Captures)");
            };
            provision.queries = QueryMap.init(ctx.allocator, config.query_count_max) catch {
                @panic("attempting to statically allocate more memory than available. (QueryMap)");
            };
            provision.request = Request.init(ctx.allocator, config.header_count_max) catch {
                @panic("attempting to statically allocate more memory than available. (Request)");
            };
            provision.response = Response.init(ctx.allocator, config.header_count_max) catch {
                @panic("attempting to statically allocate more memory than available. (Response)");
            };
        }
    }

    pub fn deinit_hook(provisions: []Provision, allocator: std.mem.Allocator) void {
        for (provisions) |*provision| {
            provision.recv_buffer.deinit();
            provision.arena.deinit();
            provision.request.deinit();
            provision.response.deinit();
            provision.queries.deinit();
            allocator.free(provision.captures);
        }
    }
};
