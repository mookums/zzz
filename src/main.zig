const std = @import("std");
const builtin = @import("builtin");
const zzz = @import("lib.zig").zzz;

const stdout = std.io.getStdOut().writer();

const Worker = @import("worker.zig").Worker;
const WorkerPool = @import("worker.zig").WorkerPool;
const Job = @import("job.zig").Job;

pub fn main() !void {
    //const host: []const u8 = "0.0.0.0";
    //const port: u16 = 9862;

    //var z3 = try zzz.init(host, port, .{ .kernel_backlog = 4096 });
    //defer z3.deinit();
    //try z3.bind();
    //try z3.listen();

    const workers = try std.heap.c_allocator.alloc(Worker, 5);

    var pool = try WorkerPool.init(std.heap.c_allocator, workers, struct {
        fn job_handler(job: Job) void {
            std.debug.print("Job: {s}\n", .{@tagName(job)});
        }
    }.job_handler);
    defer pool.deinit();

    try pool.start();
    for (0..5) |_| {
        try pool.addJob(Job{ .Noop = .{} });
    }
    try pool.abort();
}
