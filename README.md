# zzz
![zzz logo](./docs/img/zzz.png)

Tracking Latest Zig Stable: `0.13.0`

`zig fetch --save https://github.com/mookums/zzz/archive/main.tar.gz`

## zzz?
zzz is a framework for writing performant and reliable networked services in Zig. It currently only supports TCP as the underlying transport layer but allows for any arbitrary protocol to run on top.

*zzz is currently **alpha** software and while it is generally stable, there is still a lot changing at a fairly quick pace and certain places where things are less polished.*

It focuses on modularity and portability, allowing you to swap in your own implementations for various things. Consumers can provide both a protocol and an async implementation, allowing for maximum flexibility. This allows for use in standard servers as well as embedded/bare metal domains.

## Optimization
zzz is **very** fast. Through a combination of methods, such as allocation at start up and avoiding thread contention, we are able to extract tons of performance.

zzz currently out performs both [http.zig](https://github.com/karlseguin/http.zig) and [zap](https://github.com/zigzap/zap), while being almost entirely written in Zig. 

zzz can be configured to utilize minimal memory while remaining performant. The provided `minram` example only uses 392 kB!

## Features
- [Modular Asyncronous Implementation](https://muki.gg/post/modular-async)
    - Allows for passing in your own Async implementation.
    - Comes with:
        - io_uring for Linux.
        - IOCP for Windows (planned).
        - kqueue for BSD (planned).
- Modular Protocol Implementation [#](#supported-protocols)
    - Allows for defining your own Protocol on top of TCP.
- Single and Multi-threaded Support
- TLS using BearSSL
- (Almost) all memory allocated at startup
    - Only allocations happen while storing received data for parsing.

## Supported Protocols
- [HTTP/1.1](https://github.com/mookums/zzz/blob/main/src/http)
- HTTP/2 (planned)
- MQTT (planned)
- Custom, you can write your own


## Platform Support
zzz currently focuses on Linux as the primary platform. Windows, MacOS, and BSD support is planned in the near future.

Due to the modular nature, any platform (that works with Zig) can be supported as long as you define an Async backend. This includes embedded and bare metal!
