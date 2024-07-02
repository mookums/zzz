const std = @import("std");

const RequestLineError = error{ InvalidMethod, InvalidVersion, UnsupportedConversion, Generic };
pub const Version = std.http.Version;
