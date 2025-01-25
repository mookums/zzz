const std = @import("std");

const Mime = @import("../mime.zig").Mime;
const Respond = @import("../response.zig").Respond;

const Middleware = @import("../router/middleware.zig").Middleware;
const Next = @import("../router/middleware.zig").Next;
const Layer = @import("../router/middleware.zig").Layer;
const TypedMiddlewareFn = @import("../router/middleware.zig").TypedMiddlewareFn;

pub const ThreadSafeRateLimit = struct {
    map: std.AutoHashMap(u128, i64),
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator) ThreadSafeRateLimit {
        return .{
            .map = std.AutoHashMap(u128, i64).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ThreadSafeRateLimit) void {
        self.map.deinit();
    }
};

fn get_ip(addr: std.net.Address) u128 {
    return switch (addr.any.family) {
        std.posix.AF.INET => @intCast(addr.in.sa.addr),
        std.posix.AF.INET6 => std.mem.bytesAsValue(u128, &addr.in6.sa.addr[0]).*,
        else => unreachable,
    };
}

// TODO: Do a proper rate-limiter. This is super crude.
pub fn RateLimitMiddleware(comptime ms_per_request: usize, limiter: *ThreadSafeRateLimit) Layer {
    const func: TypedMiddlewareFn(*ThreadSafeRateLimit) = struct {
        fn rate_limit_mw(next: *Next, limit: *ThreadSafeRateLimit) !Respond {
            const ip = get_ip(next.context.address);
            const time = std.time.milliTimestamp();

            limit.mutex.lock();
            const addr_entry = try limit.map.getOrPut(ip);
            const last_time = addr_entry.value_ptr.*;
            addr_entry.value_ptr.* = time;
            limit.mutex.unlock();

            if (addr_entry.found_existing) {
                if (time - last_time >= ms_per_request) return try next.run();
                return Respond{
                    .status = .@"Too Many Requests",
                    .mime = Mime.TEXT,
                    .body = "",
                };
            } else return try next.run();
        }
    }.rate_limit_mw;

    return Middleware.init(limiter, func).layer();
}

fn rate_limit_mw(next: *Next, limiter: *ThreadSafeRateLimit) !Respond {
    const ip = get_ip(next.context.address);
    const time = std.time.milliTimestamp();

    limiter.mutex.lock();
    const addr_entry = try limiter.map.getOrPut(ip);
    const last_time = addr_entry.value_ptr.*;
    addr_entry.value_ptr.* = time;
    limiter.mutex.unlock();

    if (addr_entry.found_existing) {
        if (time - last_time >= std.time.ms_per_s) return try next.run();
        return Respond{
            .status = .@"Too Many Requests",
            .mime = Mime.TEXT,
            .body = "",
        };
    } else return try next.run();
}

// TODO: Consider using a C dependency here.
// Might be nice to get some fast general compression such as zstd :)
const Compression = union(enum) {
    gzip: std.compress.gzip.Options,
};

pub fn CompressMiddleware(comptime compression: Compression) Layer {
    const func: TypedMiddlewareFn(void) = switch (compression) {
        .gzip => |inner| struct {
            fn gzip_mw(next: *Next, _: void) !Respond {
                var respond = try next.run();

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
                return respond;
            }
        }.gzip_mw,
    };

    return Middleware.init({}, func).layer();
}
