const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/context");

const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;

const Capture = @import("routing_trie.zig").Capture;
const QueryMap = @import("routing_trie.zig").QueryMap;
const Provision = @import("provision.zig").Provision;

const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const ResponseSetOptions = Response.ResponseSetOptions;
const Mime = @import("mime.zig").Mime;
const _SSE = @import("sse.zig").SSE;

const Runtime = @import("tardy").Runtime;
const Task = @import("tardy").Task;
const TaskFn = @import("tardy").TaskFn;

const raw_respond = @import("server.zig").raw_respond;

// Context is dependent on the server that gets created.
pub fn Context(comptime Server: type) type {
    return struct {
        const Self = @This();
        const SSE = _SSE(Server);
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

        pub fn to_sse(self: *Self, then: TaskFn(bool, *SSE)) !void {
            assert(!self.triggered);
            self.triggered = true;

            self.response.set(.{
                .status = .OK,
                .body = "",
                .mime = Mime{
                    .extension = ".sse",
                    .description = "Server-Sent Events",
                    .content_type = "text/event-stream",
                },
            });

            const headers = try self.provision.response.headers_into_buffer(
                self.provision.buffer,
                null,
            );

            const sse = try self.allocator.create(SSE);
            sse.* = .{ .context = self };

            const pslice = Pseudoslice.init(headers, "", self.provision.buffer);

            const first_chunk = try Server.prepare_send(
                self.runtime,
                self.provision,
                .{ .sse = .{
                    .func = then,
                    .ctx = sse,
                } },
                pslice,
            );

            try self.runtime.net.send(
                self.provision,
                Server.send_then_sse_task,
                self.provision.socket,
                first_chunk,
            );
        }

        pub fn close(self: *Self) !void {
            self.provision.job = .close;
            try self.runtime.net.close(
                self.provision,
                Server.close_task,
                self.provision.socket,
            );
        }

        pub fn respond(self: *Self, options: ResponseSetOptions) !void {
            assert(!self.triggered);
            self.triggered = true;
            self.response.set(options);

            const body = options.body orelse "";
            const headers = try self.provision.response.headers_into_buffer(
                self.provision.buffer,
                @intCast(body.len),
            );
            const pslice = Pseudoslice.init(headers, body, self.provision.buffer);

            const first_chunk = try Server.prepare_send(
                self.runtime,
                self.provision,
                .recv,
                pslice,
            );

            try self.runtime.net.send(
                self.provision,
                Server.send_then_recv_task,
                self.provision.socket,
                first_chunk,
            );
        }
    };
}
