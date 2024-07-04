const std = @import("std");
const Job = @import("job.zig").Job;

pub const WorkerContext = struct {
    id: usize,
};

pub const Worker = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    func: *const fn (job: Job, pool: *WorkerPool, ctx: WorkerContext) void,
    context: WorkerContext,
    mutex: std.Thread.Mutex = std.Thread.Mutex{},
    condition: std.Thread.Condition = std.Thread.Condition{},
    submitted: std.atomic.Value(usize) = .{ .raw = 0 },
    thread: std.Thread = undefined,
    io_uring: std.os.linux.IoUring,

    pub fn init(allocator: std.mem.Allocator, context: WorkerContext, func: *const fn (job: Job, pool: *WorkerPool, ctx: WorkerContext) void) Self {
        return Self{ .allocator = allocator, .func = func, .context = context, .io_uring = std.os.linux.IoUring.init(256, 0) catch unreachable };
    }

    pub fn deinit(self: *Self) void {
        self.io_uring.deinit();
    }

    // basically, every worker is just a event loop...
    //
    // If we don't have any jobs, we try to take one of the global available jobs.
    //
    // while(true) {
    //  while(self.job_queue().isEmpty()) {
    //      pool.mutex.lock();
    //      while(self.pool.job_queue.isEmpty()) {
    //          pool.c.wait(&pool.mutex);
    //      }
    //
    //      self.job_queue.append(pool.job_queue.pop());
    //  }
    //
    //  // Complete the job and add another job onto the queue.
    // }

    /// This will create a new Thread and have the Worker operate within it.
    fn start(self: *Self, pool: *WorkerPool) !void {
        const thread = try std.Thread.spawn(.{ .allocator = self.allocator }, struct {
            fn run_jobs(s: *Self, p: *WorkerPool) void {
                while (true) {
                    // she IO on my URING until i COMPLETE
                    // she K on my QUEUE till i POP
                    while (s.io_uring.cq_ready() > 0) {
                        const cqe = s.io_uring.copy_cqe() catch continue;
                        const job: *Job = @ptrFromInt(cqe.user_data);

                        if (job.* == .Abort) {
                            s.allocator.destroy(job);
                            return;
                        }

                        @call(.auto, s.func, .{ job.*, p, s.context });
                        // Tick down submitted count.
                        _ = s.submitted.fetchSub(1, .monotonic);

                        s.allocator.destroy(job);
                    }

                    {
                        s.mutex.lock();
                        defer s.mutex.unlock();

                        while (s.submitted.load(.acquire) == 0) {
                            s.condition.wait(&s.mutex);
                        }

                        //std.debug.print("Submitted Entry Count: {d}\n", .{s.submitted});
                    }
                }
            }
        }.run_jobs, .{ self, pool });

        self.thread = thread;
    }
};

// WorkerPool manages the "global" queue.
pub const WorkerPool = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    workers: []Worker,
    worker_idx: usize = 0,
    condition: std.Thread.Condition = std.Thread.Condition{},

    pub fn init(allocator: std.mem.Allocator, workers: []Worker, func: *const fn (job: Job, pool: *WorkerPool, ctx: WorkerContext) void) !WorkerPool {
        // allocate all of the workers.
        const pool = Self{ .allocator = allocator, .workers = workers };

        for (pool.workers, 0..) |*worker, i| {
            worker.* = Worker.init(allocator, WorkerContext{ .id = i }, func);
        }

        return pool;
    }

    pub fn start(self: *Self) !void {
        for (0..self.workers.len) |i| {
            try self.workers[i].start(self);
        }
    }

    pub fn abort(self: *Self) !void {
        for (self.workers) |worker| {
            for (0..self.workers.len) |_| {
                try self.addJob(Job{ .Abort = .{} });
            }

            worker.thread.join();
        }
    }

    pub fn addJob(self: *Self, job: Job) !void {
        // she ROUND on my ROBIN til i SCHEDULE
        var worker: *Worker = &self.workers[self.worker_idx];
        self.worker_idx = (self.worker_idx + 1) % self.workers.len;

        switch (job) {
            .Read => |inner| {
                const buffer: []u8 = try self.allocator.alloc(u8, 256);
                const new_job: *Job = try self.allocator.create(Job);
                new_job.* = Job{ .Respond = .{ .stream = inner.stream, .request = buffer } };
                _ = try worker.io_uring.read(@as(u64, @intFromPtr(new_job)), inner.stream.handle, .{ .buffer = buffer }, 0);
            },

            else => {
                std.debug.print("JOB NOT SUPPORTED YET IDIOT!!!\n", .{});
            },
        }

        _ = worker.submitted.fetchAdd(try worker.io_uring.submit(), .monotonic);
        worker.condition.broadcast();
    }

    pub fn deinit(self: *Self) void {
        for (self.workers) |*worker| {
            worker.deinit();
        }

        self.allocator.free(self.workers);
    }
};
