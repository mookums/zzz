const std = @import("std");

const builtin = @import("builtin");
const assert = std.debug.assert;
const panic = std.debug.panic;
const log = std.log.scoped(.@"zzz/server");

const Async = @import("../async/lib.zig").Async;

const Job = @import("../core/lib.zig").Job;
const Pool = @import("../core/lib.zig").Pool;
const Pseudoslice = @import("../core/lib.zig").Pseudoslice;

const HTTPError = @import("lib.zig").HTTPError;
const Request = @import("lib.zig").Request;
const Response = @import("lib.zig").Response;
const Mime = @import("lib.zig").Mime;
const Context = @import("lib.zig").Context;
const Router = @import("lib.zig").Router;

const Capture = @import("routing_trie.zig").Capture;
const ProtocolData = @import("protocol.zig").ProtocolData;
const ProtocolConfig = @import("protocol.zig").ProtocolConfig;

const ZZZServer = @import("../core/server.zig").Server;

pub const Server = ZZZServer(ProtocolData, ProtocolConfig);
