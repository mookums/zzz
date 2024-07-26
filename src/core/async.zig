pub const AsyncType = enum {
    /// Only available on Linux >= 5.1
    /// Preferred on Linux over epoll.
    io_uring,
    /// Only available on Linux >= 2.5.45
    epoll,
    /// Only available on BSD >= 4.1
    kqueue,
    /// Only available on Windows >= 3.5
    iocp,
    /// Available on all targets.
    custom,
};

pub const AsyncCustom = struct {};

pub const Async = union(enum) {
    io_uring,
    epoll,
    kqueue,
    iocp,
    custom: AsyncCustom,
};
