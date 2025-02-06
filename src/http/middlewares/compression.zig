const std = @import("std");

const Respond = @import("../response.zig").Respond;
const Middleware = @import("../router/middleware.zig").Middleware;
const Next = @import("../router/middleware.zig").Next;
const Layer = @import("../router/middleware.zig").Layer;
const TypedMiddlewareFn = @import("../router/middleware.zig").TypedMiddlewareFn;

const Kind = union(enum) {
    gzip: std.compress.gzip.Options,
};

/// Compression Middleware.
///
/// Provides a Compression Layer for all routes under this that
/// will properly compress the body and add the proper `Content-Encoding` header.
pub fn Compression(comptime compression: Kind) Layer {
    const func: TypedMiddlewareFn(void) = switch (compression) {
        .gzip => |inner| struct {
            fn gzip_mw(next: *Next, _: void) !Respond {
                var response = try next.run();
                switch (response) {
                    .standard => |*respond| {
                        var compressed = std.ArrayList(u8).init(next.context.allocator);

                        var body_stream = std.io.fixedBufferStream(respond.body);
                        try std.compress.gzip.compress(body_stream.reader(), compressed.writer(), inner);

                        // TODO: consider having the headers be a part of the provision?
                        // might be nice to reuse them as things go on??
                        var header_list = std.ArrayList([2][]const u8).init(next.context.allocator);
                        try header_list.appendSlice(respond.headers);
                        try header_list.append(.{ "Content-Encoding", "gzip" });

                        respond.body = try compressed.toOwnedSlice();
                        respond.headers = try header_list.toOwnedSlice();
                        return .{ .standard = respond.* };
                    },
                    else => return response,
                }
            }
        }.gzip_mw,
    };

    return Middleware.init({}, func).layer();
}
