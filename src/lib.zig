const std = @import("std");

pub const Async = @import("async/lib.zig").Async;
pub const AsyncError = @import("async/lib.zig").AsyncError;
pub const AsyncOptions = @import("async/lib.zig").AsyncOptions;
pub const Completion = @import("async/completion.zig").Completion;

pub const Socket = @import("core/socket.zig").Socket;

/// HyperText Transfer Protocol.
/// Supports: HTTP/1.1
pub const HTTP = @import("http/lib.zig");
