pub const SSL = struct {
    inner: *anyopaque,
    _create_context: *const fn (self: *SSL, cert: []const u8, key: []const u8) void,
    _accept: *const fn (self: *SSL, cert: []const u8, key: []const u8) void,
    _encrypt: *const fn (self: *SSL, msg: []const u8) void,
    _decrypt: *const fn (self: *SSL, encrypted: []const u8) void,
};
