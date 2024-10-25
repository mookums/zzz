const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/context");

const Capture = @import("routing_trie.zig").Capture;
const QueryMap = @import("routing_trie.zig").QueryMap;

const Provision = @import("../core/zprovision.zig").ZProvision(@import("protocol.zig").ProtocolData);

const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const ResponseSetOptions = Response.ResponseSetOptions;

const Runtime = @import("tardy").Runtime;
const Task = @import("tardy").Task;
// Needed here to prevent a dependency loop.
const TaskFn = *const fn (*Runtime, *const Task, ?*anyopaque) anyerror!void;

const raw_respond = @import("server.zig").raw_respond;

pub const Context = struct {
    allocator: std.mem.Allocator,
    trigger: TaskFn,
    runtime: *Runtime,
    /// The Request that triggered this handler.
    request: *const Request,
    /// The Response that will be returned.
    /// To actually trigger the send, use `Context.respond`.
    response: *Response,
    path: []const u8,
    captures: []Capture,
    queries: *QueryMap,
    provision: *Provision,
    triggered: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        trigger: TaskFn,
        runtime: *Runtime,
        ctx: *Provision,
        request: *const Request,
        response: *Response,
        path: []const u8,
        captures: []Capture,
        queries: *QueryMap,
    ) Context {
        return Context{
            .allocator = allocator,
            .trigger = trigger,
            .runtime = runtime,
            .provision = ctx,
            .request = request,
            .response = response,
            .path = path,
            .captures = captures,
            .queries = queries,
        };
    }

    pub fn respond(self: *Context, options: ResponseSetOptions) void {
        assert(!self.triggered);
        self.triggered = true;
        self.response.set(options);

        // Keep alive.
        self.response.headers.add("Connection", "keep-alive") catch unreachable;

        // this will write the data into the appropriate places.
        const status = raw_respond(self.provision) catch unreachable;

        self.provision.job = .{
            .send = .{
                .count = 0,
                .slice = status.send,
                .security = undefined,
            },
        };

        self.runtime.spawn(.{
            .func = self.trigger,
            .ctx = self.provision,
        }) catch unreachable;
    }
};
