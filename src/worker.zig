const std = @import("std");
const Job = @import("job.zig").Job;

pub const Worker = struct {
    const Self = @This();
    allocator: std.mem.Allocator,
    func: *const fn (job: Job) void,
    thread: std.Thread = undefined,
    job_queue: std.DoublyLinkedList(Job) = std.DoublyLinkedList(Job){},

    pub fn init(allocator: std.mem.Allocator, func: *const fn (job: Job) void) Self {
        return Self{ .allocator = allocator, .func = func };
    }

    pub fn deinit(self: *Self) void {
        while (self.job_queue.pop()) |node| {
            self.allocator.destroy(node);
        }
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
                    while (s.job_queue.popFirst()) |node| {
                        // Experiment with creating an arena allocator here and giving that to the job.

                        // We have a job.
                        if (node.data == .Abort) {
                            s.allocator.destroy(node);
                            return;
                        }

                        @call(std.builtin.CallModifier.auto, s.func, .{node.data});

                        // Destroy Job.
                        s.allocator.destroy(node);
                    } else {
                        // We don't have a job.

                        // Get a lock on the pool's job queue.
                        p.mutex.lock();
                        const new_node = wait_for_job: while (true) {
                            if (p.job_queue.popFirst()) |node| {
                                break :wait_for_job node;
                            } else {
                                // Wait.
                                p.condition.wait(&p.mutex);
                            }
                        };

                        // Make sure this is correct order.
                        p.mutex.unlock();
                        s.job_queue.append(new_node);
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
    job_queue: std.DoublyLinkedList(Job) = std.DoublyLinkedList(Job){},
    mutex: std.Thread.Mutex = std.Thread.Mutex{},
    condition: std.Thread.Condition = std.Thread.Condition{},

    pub fn init(allocator: std.mem.Allocator, workers: []Worker, func: *const fn (job: Job) void) !WorkerPool {
        // allocate all of the workers.
        const pool = Self{ .allocator = allocator, .workers = workers };

        for (pool.workers) |*worker| {
            worker.* = Worker.init(allocator, func);
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
        const node = try self.allocator.create(std.DoublyLinkedList(Job).Node);
        node.* = .{ .data = job };

        self.mutex.lock();
        self.job_queue.append(node);
        self.condition.signal();
        self.mutex.unlock();
    }

    pub fn deinit(self: *Self) void {
        for (self.workers) |*worker| {
            worker.deinit();
        }

        self.allocator.free(self.workers);

        while (self.job_queue.pop()) |node| {
            self.allocator.destroy(node);
        }
    }
};
