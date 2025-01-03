## Performance
zzz's design philosophy results in a lot of knobs that the consumer of the library can turn and tune to their preference.

These performance tips are general and can apply to any protocol implementation. HTTP is used as the general example because it is currently the only completed protocol.

## Performance Hunting
zzz now officially runs multithreaded by default. By default, it will utilize `@min(cpu_count / 2 - 1, 1)` threads. This can be tuned by changing the `.threading` option of the Tardy runtime. 

```zig
var t = try Tardy.init(.{
    .allocator = allocator,
    .threading = .{ .multi = COUNT },
});
```

The most important part of switching to the multi threaded model is using a **thread-safe** allocator. The general purpose allocator with the thread safe flag is an ideal choice.

Another way to alter the performance is by changing which Async I/O model you use. `.auto` will select the best one overall but there are other options that may be worth benchmarking
depending on your use case.

Other settings of note include:
- `connection_arena_bytes_retain` which controls how much memory that has been allocated within a connection's arena will be retained for the next connection.
- `connections_size_max` which controls the maximum number of connections that each thread can handle.  Any connection after this number will get closed.

## Minimizing Memory Usage
When using zzz in certain environments, your goal may be to reduce memory usage. zzz provides a variety of controls for handling how much memory is allocated at start up.

```zig
var server = Server.init(rt.allocator, .{
    .backlog_count = 32,
    .connection_count_max = 16,
    .connections_size_max = 16,
    .connection_arena_bytes_retain = 64,
    .socket_buffer_bytes = 512,
});
```

There is no overarching setting here but a selection of ones you can tune to minimize:
- run in single threaded mode
- `connections_size_max` can be reduced. This value is used internally as every connection on every thread owns a `Provision`.
- `connection_arena_bytes_retain` can be reduced. If you are not doing any allocations within the handler, you can even set this to 0.
- `socket_buffer_bytes` can be reduced. There is a lower limit to this value of around 128 bytes. (This will be changed in the future and internal buffers will be separated).

