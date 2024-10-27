const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/context");

const Capture = @import("routing_trie.zig").Capture;
const QueryMap = @import("routing_trie.zig").QueryMap;
const Provision = @import("provision.zig").Provision;

const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const ResponseSetOptions = Response.ResponseSetOptions;

const Runtime = @import("tardy").Runtime;
const Task = @import("tardy").Task;

const raw_respond = @import("server.zig").raw_respond;

// Context is dependent on the server that gets created.
// This is because the trigger_task ends up being dependent.
pub fn Context(comptime Server: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        /// The Request that triggered this handler.
        request: *const Request,
        /// The Response that will be returned.
        response: *Response,
        path: []const u8,
        captures: []Capture,
        queries: *QueryMap,
        provision: *Provision,
        triggered: bool = false,

        pub fn respond(self: *Self, options: ResponseSetOptions) void {
            assert(!self.triggered);
            self.triggered = true;
            self.response.set(options);

            // this will write the data into the appropriate places.
            const status = raw_respond(self.provision) catch unreachable;

            self.provision.job = .{
                .send = .{
                    .count = 0,
                    .slice = status.send,
                    .security = undefined,
                },
            };

            const body = options.body orelse "";

            const first_chunk = Server.prepare_send(
                self.runtime,
                self.provision,
                body,
                @intCast(body.len),
            ) catch unreachable;

            self.runtime.net.send(
                *Provision,
                Server.send_task,
                self.provision,
                self.provision.socket,
                first_chunk,
            ) catch unreachable;
        }
    };
}
