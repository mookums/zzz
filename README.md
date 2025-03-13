# zzz
![zzz logo](./docs/img/zzz.png)


## Installing
Compatible Zig Version: `0.14.0`

Compatible [tardy](https://github.com/tardy-org/tardy) Version: `v0.3.0`

Latest Release: `0.3.0`
```
zig fetch --save git+https://github.com/tardy-org/zzz#v0.3.0
```

You can then add the dependency in your `build.zig` file:
```zig
const zzz = b.dependency("zzz", .{
    .target = target,
    .optimize = optimize,
}).module("zzz");

exe.root_module.addImport(zzz);
```

## zzz?
zzz is a framework for writing performant and reliable networked services in Zig. It supports both HTTP and HTTPS.

zzz currently supports Linux, Mac and Windows. Linux is currently the recommended target for deployments.

> [!IMPORTANT]
> zzz is currently **alpha** software and there is still a lot changing at a fairly quick pace and certain places where things are less polished.

It focuses on modularity and portability, allowing you to swap in your own implementations for various things. Consumers can provide an async implementation, allowing for maximum flexibility. This allows for use in standard servers as well as embedded/bare metal domains.

For more information, look here:
1. [Getting Started](./docs/getting_started.md)
2. [HTTPS](./docs/https.md)

## Optimization
zzz is **very** fast. Through a combination of methods, such as allocation at start up and avoiding thread contention, we are able to extract tons of performance out of a fairly simple implementation. zzz is quite robust currently but is still early stage software. It's currently been running in production, serving my [site](https://muki.gg).

With the recent migration to [tardy](https://github.com/tardy-org/tardy), zzz is about as fast as gnet, the fastest plaintext HTTP server according to [TechEmpower](https://www.techempower.com/benchmarks/#hw=ph&test=plaintext&section=data-r22), while consuming only ~22% of the memory that gnet requires.

![benchmark (request per sec)](./docs/benchmark/req_per_sec_ccx63_24.png)

[Raw Data](./docs/benchmark/request_ccx63_24.csv)

![benchmark (peak memory)](./docs/benchmark/peak_memory_ccx63_24.png)

[Raw Data](./docs/benchmark/memory_ccx63_24.csv)

On the CCX63 instance on Hetzner with 2000 max connections, we are 70.9% faster than [zap](https://github.com/zigzap/zap) and 83.8% faster than [http.zig](https://github.com/karlseguin/http.zig). We also utilize less memory, using only ~3% of the memory used by zap and ~1.6% of the memory used by http.zig.

zzz can be configured to utilize minimal memory while remaining performant. The provided `minram` example only uses 256 kB!

## Features
- Built on top of [Tardy](https://github.com/tardy-org/tardy), an asynchronous runtime.
- [Modular Asynchronous Implementation](https://muki.gg/post/modular-async)
    - `io_uring` for Linux (>= 5.1.0).
    - `epoll` for Linux (>= 2.5.45).
    - `kqueue` for BSD & Mac.
    - `poll` for Linux, Mac and Windows.
- Layered Router, including Middleware
- Single and Multithreaded Support
- TLS using [secsock](https://github.com/tardy-org/secsock) 
- Memory Pooling for minimal allocations 

## Contribution
Unless you explicitly state otherwise, any contribution intentionally submitted for inclusion in zzz by you, shall be licensed as MPL2.0, without any additional terms or conditions.
