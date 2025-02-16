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
                const respond = try next.run();
                const response = next.context.response;
                if (response.body) |body| if (respond == .standard) {
                    var compressed = try std.ArrayListUnmanaged(u8).initCapacity(next.context.allocator, body.len);
                    errdefer compressed.deinit(next.context.allocator);

                    var body_stream = std.io.fixedBufferStream(body);
                    try std.compress.gzip.compress(
                        body_stream.reader(),
                        compressed.writer(next.context.allocator),
                        inner,
                    );

                    try response.headers.put("Content-Encoding", "gzip");
                    response.body = try compressed.toOwnedSlice(next.context.allocator);
                    return .standard;
                };

                return respond;
            }
        }.gzip_mw,
    };

    return Middleware.init({}, func).layer();
}
