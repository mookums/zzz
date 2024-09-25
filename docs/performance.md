## Performance
zzz's design philosophy results in a lot of knobs that the consumer of the library can turn and tune to their preference.

These performance tips are general and can apply to any protocol implementation. HTTP is used as the general example because it is currently the only completed protocol.

## Performance Hunting
When seeking out maximum performance, one of the most important settings to change is the `.threading` setting of the server. By default, zzz runs in a single threaded mode (likely to change in a future development cycle). 

```zig
var server = http.Server(.plain, .auto).init(.{
    .allocator = allocator,
});
```
This means that you can gain the largest performance boon by simply adding this one line:
```zig
var server = http.Server(.plain, .auto).init(.{
    .allocator = allocator,
    .threading = .{ .multi_threaded = .auto },
});
```

The most important part of switching to the multi threaded model is using a **thread-safe** allocator. The general purpose allocator with the thread safe flag is an ideal choice.

Other settings of note include:
-  `size_connection_arena_retain` which controls how much memory that has been allocated within a connection's arena will be retained for the next connection. 
- `size_connections_max` which controls the maximum number of connections that each thread can handle.  Any connection after this number will get closed.
- `ms_operation_max` which controls the maximum amount of milliseconds that a connection can wait for an operation. Any operation that takes longer than this will timeout and get canceled. You can set this to null to disable timeouts.

## Minimizing Memory Usage
When using zzz in certain environments, your goal may be to reduce memory usage. zzz provides a variety of controls for handling how much memory is allocated at start up.

```zig
var server = http.Server(.plain, .auto).init(.{
    .allocator = allocator,
    .size_backlog = 32,
    .size_connections_max = 16,
    .size_connection_arena_retain = 64,
    .size_socket_buffer = 512,
});
```

There is no overarching setting here but a selection of ones you can tune to minimize:
- run in single threaded mode
- `size_connections_max` can be reduced. This value is used internally as every connection on every thread owns a `Provision`.
- `size_connection_arena_retain` can be reduced. If you are not doing any allocations within the handler, you can even set this to 0.
- `size_socket_buffer` can be reduced. There is a lower limit to this value of around 128 bytes. (This will be changed in the future and internal buffers will be separated).
- `ms_operation_max` which controls the maximum amount of milliseconds that a connection can wait for an operation. With a small number of maximum connections, setting this value appropriately is important to ensure you can service multiple clients.

