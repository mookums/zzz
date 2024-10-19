const std = @import("std");
const panic = std.debug.panic;
const Job = @import("../core/lib.zig").Job;
const TLS = @import("../tls/lib.zig").TLS;

pub fn ZProvision(comptime ProtocolData: type) type {
    return struct {
        const Self = @This();
        index: usize,
        job: Job,
        socket: std.posix.socket_t,
        buffer: []u8,
        recv_buffer: std.ArrayList(u8),
        arena: std.heap.ArenaAllocator,
        data: ProtocolData,

        pub fn init_hook(provisions: []Self, ctx: anytype) void {
            for (provisions) |*provision| {
                provision.job = .empty;
                provision.socket = undefined;
                provision.data = undefined;
                // Create Buffer
                provision.buffer = ctx.allocator.alloc(u8, ctx.size_socket_buffer) catch {
                    panic("attempting to statically allocate more memory than available. (Socket Buffer)", .{});
                };
                // Create Recv Buffer
                provision.recv_buffer = std.ArrayList(u8).init(ctx.allocator);
                // Create the Context Arena
                provision.arena = std.heap.ArenaAllocator.init(ctx.allocator);
            }
        }

        pub fn deinit_hook(provisions: []Self, allocator: anytype) void {
            for (provisions) |*provision| {
                allocator.free(provision.buffer);
                provision.recv_buffer.deinit();
                provision.arena.deinit();
            }
        }
    };
}
