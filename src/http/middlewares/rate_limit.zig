const std = @import("std");

const Mime = @import("../mime.zig").Mime;
const Respond = @import("../response.zig").Respond;
const Response = @import("../response.zig").Response;
const Middleware = @import("../router/middleware.zig").Middleware;
const Next = @import("../router/middleware.zig").Next;
const Layer = @import("../router/middleware.zig").Layer;
const TypedMiddlewareFn = @import("../router/middleware.zig").TypedMiddlewareFn;

/// Rate Limiting Middleware.
///
/// Provides a IP-matching Bucket-based Rate Limiter.
pub fn RateLimiting(config: *RateLimitConfig) Layer {
    const func: TypedMiddlewareFn(*RateLimitConfig) = struct {
        fn rate_limit_mw(next: *Next, c: *RateLimitConfig) !Respond {
            const ip = get_ip(next.context.socket.inner.addr);
            const time = std.time.milliTimestamp();

            c.mutex.lock();
            const entry = try c.map.getOrPut(ip);

            if (entry.found_existing) {
                entry.value_ptr.replenish(time, c.tokens_per_sec, c.max_tokens);
                if (entry.value_ptr.take()) {
                    c.mutex.unlock();
                    return try next.run();
                }
                c.mutex.unlock();

                return c.response_on_limited;
            }

            entry.value_ptr.* = .{ .tokens = c.max_tokens, .last_refill_ms = time };
            c.mutex.unlock();
            return try next.run();
        }
    }.rate_limit_mw;

    return Middleware.init(config, func).layer();
}

pub const RateLimitConfig = struct {
    map: std.AutoHashMap(u128, Bucket),
    tokens_per_sec: u16,
    max_tokens: u16,
    response_on_limited: Response.Fields,
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        tokens_per_sec: u16,
        max_tokens: u16,
        response_on_limited: ?Respond,
    ) RateLimitConfig {
        const map = std.AutoHashMap(u128, Bucket).init(allocator);
        const respond = response_on_limited orelse Response.Fields{
            .status = .@"Too Many Requests",
            .mime = Mime.TEXT,
            .body = "",
        };

        return .{
            .map = map,
            .tokens_per_sec = tokens_per_sec,
            .max_tokens = max_tokens,
            .response_on_limited = respond,
        };
    }

    pub fn deinit(self: *RateLimitConfig) void {
        self.map.deinit();
    }
};

const Bucket = struct {
    tokens: u16,
    last_refill_ms: i64,

    pub fn replenish(self: *Bucket, time_ms: i64, tokens_per_sec: u16, max_tokens: u16) void {
        const delta_ms = time_ms - self.last_refill_ms;
        const new_tokens: u16 = @intCast(@divFloor(delta_ms * tokens_per_sec, std.time.ms_per_s));
        self.tokens = @min(max_tokens, self.tokens + new_tokens);
        self.last_refill_ms = time_ms;
    }

    pub fn take(self: *Bucket) bool {
        if (self.tokens > 0) {
            self.tokens -= 1;
            return true;
        }

        return false;
    }
};

fn get_ip(addr: std.net.Address) u128 {
    return switch (addr.any.family) {
        std.posix.AF.INET => @intCast(addr.in.sa.addr),
        std.posix.AF.INET6 => std.mem.bytesAsValue(u128, &addr.in6.sa.addr[0]).*,
        else => @panic("Not an IP address."),
    };
}
