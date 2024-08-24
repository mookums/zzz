const std = @import("std");
const http = @import("http/lib.zig");

//pub const Server = @import("http/server.zig").Server;
pub const Server2 = @import("http/server2.zig").Server;
pub const Status = http.Router;
pub const Method = http.Method;
pub const Mime = http.Mime;
pub const Request = http.Request;
pub const Response = http.Response;
pub const Router = http.Router;
pub const Route = http.Route;
pub const Context = http.Context;
