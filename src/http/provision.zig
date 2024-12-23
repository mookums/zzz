const std = @import("std");

const Job = @import("../core/job.zig").Job;
const ZeroCopyBuffer = @import("../core/zc_buffer.zig").ZeroCopyBuffer;
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
    index: usize,
    job: Job,
    socket: std.posix.socket_t,
    buffer: []u8,
    recv_buffer: ZeroCopyBuffer,
    arena: std.heap.ArenaAllocator,
    captures: []Capture,
    queries: QueryMap,
    request: Request,
    response: Response,
    stage: Stage,
    context: Context,

    pub const InitContext = struct {
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        config: ServerConfig,
    };

    pub fn init_hook(provisions: []Provision, ctx: InitContext) void {
        const config = ctx.config;
        for (provisions) |*provision| {
            provision.job = .empty;
            provision.socket = undefined;
            // Create Recv Buffer
            provision.recv_buffer = ZeroCopyBuffer.init(ctx.allocator, config.socket_buffer_bytes) catch {
                @panic("attempting to statically allocate more memory than available. (ZeroCopyBuffer)");
            };
            // Create Buffer
            provision.buffer = provision.recv_buffer.get_write_area_assume_space(config.socket_buffer_bytes);
            // Create the Context Arena
            provision.arena = std.heap.ArenaAllocator.init(ctx.allocator);

            provision.stage = .header;
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

            // Anything undefined within here is sourced at Handler time.
            provision.context = .{
                .provision = provision,
                .allocator = provision.arena.allocator(),
                .request = &provision.request,
                .response = &provision.response,
                .runtime = ctx.runtime,
                .next = .{
                    .ctx = &provision.context,
                    .stage = .pre,
                    // Handler Time.
                    .pre_chain = undefined,
                    .post_chain = undefined,
                },

                // Handler Time.
                .captures = undefined,
                .queries = undefined,
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
