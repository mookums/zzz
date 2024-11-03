const std = @import("std");
const meta = @import("./meta.zig");
const t = std.testing;
// Source: https://github.com/cztomsik/tokamak/blob/main/src/injector.zig
/// Injector serves as a custom runtime scope for retrieving dependencies.
/// It can be passed around, enabling any code to request a value or reference
/// to a given type. Additionally, it can invoke arbitrary functions and supply
/// the necessary dependencies automatically.
///
/// Injectors can be nested. If a dependency is not found, the parent context
/// is searched. If the dependency is still not found, an error is returned.
pub const Injector = struct {
    ctx: *anyopaque,
    resolver: *const fn (*anyopaque, meta.TypeId) ?*anyopaque,
    parent: ?*const Injector = null,

    pub const empty: Injector = .{ .ctx = undefined, .resolver = resolveNull };

    /// Create a new injector from a context ptr and an optional parent.
    pub fn init(ctx: anytype, parent: ?*const Injector) Injector {
        if (comptime !meta.isOnePtr(@TypeOf(ctx))) {
            @compileError("Expected pointer to a context, got " ++ @typeName(@TypeOf(ctx)));
        }

        const H = struct {
            fn resolve(ptr: *anyopaque, tid: meta.TypeId) ?*anyopaque {
                var cx: @TypeOf(ctx) = @constCast(@ptrCast(@alignCast(ptr)));

                inline for (std.meta.fields(@TypeOf(cx.*))) |f| {
                    const p = if (comptime meta.isOnePtr(f.type)) @field(cx, f.name) else &@field(cx, f.name);

                    if (tid == meta.tid(@TypeOf(p))) {
                        std.debug.assert(@intFromPtr(p) != 0xaaaaaaaaaaaaaaaa);
                        return @ptrCast(@constCast(p));
                    }
                }

                if (tid == meta.tid(@TypeOf(cx))) {
                    return ptr;
                }

                return null;
            }
        };

        return .{
            .ctx = @constCast(@ptrCast(ctx)), // resolver() casts back first, so this should be safe
            .resolver = &H.resolve,
            .parent = parent,
        };
    }

    pub fn find(self: Injector, comptime T: type) ?T {
        if (comptime T == Injector) {
            return self;
        }

        if (comptime !meta.isOnePtr(T)) {
            return if (self.find(*const T)) |p| p.* else null;
        }

        if (self.resolver(self.ctx, meta.tid(T))) |ptr| {
            return @ptrCast(@constCast(@alignCast(ptr)));
        }

        if (comptime @typeInfo(T).Pointer.is_const) {
            if (self.resolver(self.ctx, meta.tid(*@typeInfo(T).Pointer.child))) |ptr| {
                return @ptrCast(@constCast(@alignCast(ptr)));
            }
        }

        return if (self.parent) |p| p.find(T) else null;
    }

    /// Get a dependency from the context.
    pub fn get(self: Injector, comptime T: type) !T {
        return self.find(T) orelse {
            std.log.debug("Missing dependency: {s}", .{@typeName(T)});
            return error.MissingDependency;
        };
    }

    test get {
        var num: u32 = 123;
        var cx = .{ .num = &num };
        const inj = Injector.init(&cx, null);

        try t.expectEqual(inj, inj.get(Injector));
        try t.expectEqual(&num, inj.get(*u32));
        try t.expectEqual(@as(*const u32, &num), inj.get(*const u32));
        try t.expectEqual(123, inj.get(u32));
        try t.expectEqual(error.MissingDependency, inj.get(u64));
    }

    /// Call a function with dependencies. The `extra_args` tuple is used to
    /// pass additional arguments to the function. Function with anytype can
    /// be called as long as the concrete value is provided in the `extra_args`.
    pub fn call(self: Injector, comptime fun: anytype, extra_args: anytype) anyerror!meta.Result(fun) {
        if (comptime @typeInfo(@TypeOf(extra_args)) != .@"struct") {
            @compileError("Expected a tuple of arguments");
        }

        const params = @typeInfo(@TypeOf(fun)).@"fn".params;
        const extra_start = params.len - extra_args.len;

        const types = comptime brk: {
            var types: [params.len]type = undefined;
            for (0..extra_start) |i| types[i] = params[i].type orelse @compileError("reached anytype");
            for (extra_start..params.len, 0..) |i, j| types[i] = @TypeOf(extra_args[j]);
            break :brk &types;
        };

        var args: std.meta.Tuple(types) = undefined;
        inline for (0..args.len) |i| args[i] = if (i < extra_start) try self.get(@TypeOf(args[i])) else extra_args[i - extra_start];

        return @call(.auto, fun, args);
    }
};

fn resolveNull(_: *anyopaque, _: meta.TypeId) ?*anyopaque {
    return null;
}
