# HTTPS
zzz utilizes [BearSSL](https://bearssl.org/) to provide a safe and performant TLS implementation. This TLS functionality is entirely separated from the I/O for maximum portability.

*Note: TLS Support is not **entirely** complete yet. It's a very rough area that will be getting cleaned up in a future development cycle*

## TLS Example
This is derived from the example at `src/examples/tls` and utilizes some certificates that are present within the repository.
```zig
const std = @import("std");
const zzz = @import("zzz");
const http = zzz.HTTP;
const log = std.log.scoped(.@"examples/tls");

pub fn main() !void {
    const host: []const u8 = "0.0.0.0";
    const port: u16 = 9862;

    const allocator = std.heap.page_allocator;

    var router = http.Router.init(allocator);
    defer router.deinit();
    
    try router.serve_route("/", http.Route.init().get(struct {
        pub fn handler_fn(_: http.Request, response: *http.Response, _: http.Context) void {
            const body =
                \\ <!DOCTYPE html>
                \\ <html>
                \\ <body>
                \\ <h1>Hello, World!</h1>
                \\ </body>
                \\ </html>
            ;

            response.set(.{
                .status = .OK,
                .mime = http.Mime.HTML,
                .body = body[0..],
            });
        }
    }.handler_fn));

    var server = http.Server(.{
        .tls = .{
            .cert = .{
                .file = .{ .path = "src/examples/tls/certs/cert.pem" },
            },
            .key = .{
                .file = .{ .path = "src/examples/tls/certs/key.pem" },
            },
            .cert_name = "CERTIFICATE",
            .key_name = "EC PRIVATE KEY",
        },
    }).init(.{
        .allocator = allocator,
    }, null);
    defer server.deinit();

    try server.bind(host, port);
    try server.listen(.{ .router = &router });
}
```
This example above passes the `.tls` variant of the enum to the HTTP Server and provides the location of the certificate and key to be used. It also has the functionality to pass in a buffer containing the cert and key data if that is preferable. You must also provide the certificate and key name as the PEM format allows for multiple items to be placed within the same file.

