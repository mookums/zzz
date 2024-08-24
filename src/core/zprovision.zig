const std = @import("std");
const panic = std.debug.panic;
const Socket = @import("socket.zig").Socket;
const Job = @import("../core/lib.zig").Job;

pub fn ZProvision(comptime ProtocolData: type) type {
    return struct {
        const Self = @This();
        index: usize,
        job: Job,
        socket: Socket,
        sock_buffer: []u8,
        recv_buffer: std.ArrayList(u8),
        arena: std.heap.ArenaAllocator,
        pdata: ProtocolData,

        pub fn init_hook(provisions: []Self, ctx: anytype) void {
            for (provisions) |*provision| {
                provision.socket = undefined;
                // Create Buffer
                provision.sock_buffer = ctx.allocator.alloc(u8, ctx.size_socket_buffer) catch {
                    panic("attempting to statically allocate more memory than available. (Socket Buffer)", .{});
                };
                // Create Recv Buffer
                provision.recv_buffer = std.ArrayList(u8).init(ctx.allocator);
                // Create the Context Arena
                provision.arena = std.heap.ArenaAllocator.init(ctx.allocator);
                // Create the protocol data.
                provision.pdata = undefined;
            }
        }

        pub fn deinit_hook(provisions: []Self, ctx: anytype) void {
            for (provisions) |*provision| {
                ctx.allocator.free(provision.sock_buffer);
                provision.recv_buffer.deinit();
                provision.arena.deinit();
            }
        }
    };
}
