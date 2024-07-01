const std = @import("std");

pub const AtomicThreadManager = struct {
    thread_count: std.atomic.Value(usize),
    max_thread_count: usize,
    const Self = @This();

    pub inline fn init(max_threads: usize) Self {
        return Self{
            .thread_count = .{ .raw = 0 },
            .max_thread_count = max_threads,
        };
    }

    pub inline fn increment(self: *Self) void {
        _ = self.thread_count.fetchAdd(1, .monotonic);
    }

    pub inline fn decrement(self: *Self) void {
        _ = self.thread_count.fetchSub(1, .monotonic);
    }

    pub inline fn canSpawn(self: *Self) bool {
        return self.thread_count.load(.monotonic) < self.max_thread_count;
    }
};

pub const LockingThreadManager = struct {
    thread_count: usize = 0,
    max_thread_count: usize,
    lock: std.Thread.RwLock = std.Thread.RwLock{},
    const Self = @This();

    pub inline fn init(max_threads: usize) Self {
        return Self{
            .max_thread_count = max_threads,
        };
    }

    pub inline fn increment(self: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.thread_count += 1;
    }

    pub inline fn decrement(self: *Self) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.thread_count -= 1;
    }

    pub inline fn canSpawn(self: *Self) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.thread_count < self.max_thread_count;
    }
};
