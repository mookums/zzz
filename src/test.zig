const std = @import("std");
const testing = std.testing;

pub const Core = @import("./core/lib.zig");
pub const HTTP = @import("./http/lib.zig");

test "all of zzz" {
    testing.refAllDeclsRecursive(@This());
}
