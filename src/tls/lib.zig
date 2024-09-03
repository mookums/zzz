pub const TLSFileOptions = union(enum) {
    buffer: []const u8,
    file: struct {
        path: []const u8,
        size_buffer_max: u32 = 1024 * 1024,
    },
};

pub const TLSContext = @import("bear.zig").TLSContext;
pub const TLS = @import("bear.zig").TLS;
