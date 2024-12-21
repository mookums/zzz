const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.@"zzz/http/context");

const Pseudoslice = @import("../core/pseudoslice.zig").Pseudoslice;

const Capture = @import("router/routing_trie.zig").Capture;
const QueryMap = @import("router/routing_trie.zig").QueryMap;
const Route = @import("router/route.zig").Route;
const Provision = @import("provision.zig").Provision;

const Request = @import("request.zig").Request;
const Response = @import("response.zig").Response;
const ResponseSetOptions = Response.ResponseSetOptions;
const Mime = @import("mime.zig").Mime;
const _SSE = @import("sse.zig").SSE;

const Runtime = @import("tardy").Runtime;
const TaskFn = @import("tardy").TaskFn;

// Context is dependent on the server that gets created.
pub fn Context(comptime Server: type, comptime AppState: type) type {
    return struct {
        const Self = @This();
        const SSE = _SSE(Server, AppState);
        allocator: std.mem.Allocator,
        runtime: *Runtime,
        /// Custom user-data state.
        state: AppState,
        /// The matched route instance.
        route: ?*const Route(Server, AppState),
        /// The Request that triggered this handler.
        request: *const Request,
        /// The Response that will be returned.
        response: *Response,
        captures: []Capture,
        queries: *QueryMap,
        provision: *Provision,
        triggered: bool = false,

        pub fn to_sse(self: *Self, then: TaskFn(bool, *SSE)) !void {
            const sse = try self.allocator.create(SSE);
            sse.* = .{
                .context = self,
                .runtime = self.runtime,
                .allocator = self.allocator,
            };

            try self.respond_headers_only(
                .{
                    .status = .OK,
                    .mime = Mime.generate(
                        "text/event-stream",
                        "sse",
                        "Server-Sent Events",
                    ),
                },
                null,
                sse,
                then,
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

        pub fn send_then(
            self: *Self,
            data: []const u8,
            ctx: anytype,
            then: TaskFn(bool, @TypeOf(ctx)),
        ) !void {
            const pslice = Pseudoslice.init(data, "", self.provision.buffer);

            const first_chunk = try Server.prepare_send(
                self.runtime,
                self.provision,
                .{
                    .other = .{
                        .func = then,
                        .ctx = ctx,
                    },
                },
                pslice,
            );

            try self.runtime.net.send(
                self.provision,
                Server.send_then_other_task,
                self.provision.socket,
                first_chunk,
            );
        }

        pub fn send_then_recv(self: *Self, data: []const u8) !void {
            const pslice = Pseudoslice.init(data, "", self.provision.buffer);

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

        // This will respond with the headers only.
        // You will be in charge of sending the body.
        pub fn respond_headers_only(
            self: *Self,
            options: ResponseSetOptions,
            content_length: ?usize,
            ctx: anytype,
            then: TaskFn(bool, @TypeOf(ctx)),
        ) !void {
            assert(!self.triggered);
            self.triggered = true;

            // the body should not be set.
            assert(options.body == null);
            self.response.set(options);

            const headers = try self.provision.response.headers_into_buffer(
                self.provision.buffer,
                content_length,
            );

            try self.send_then(headers, ctx, then);
        }

        /// This is your standard response.
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
