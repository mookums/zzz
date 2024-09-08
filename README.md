# zzz

## Notice
zzz is currently **alpha** software and while it is generally stable, there is still a lot changing at a fairly quick pace and certain places where things are less polished.

You should currently only use it if you are willing to work around the rough edges.

## zzz?
zzz is a framework for writing performant and reliable networked services in Zig.

zzz provides a solid core with support for providing your own protocol handlers and your own Async implementation.

It focuses on modularity and portability, allowing you to swap in your own implementations for various things. This allows for use in standard servers as well as embedded/bare metal domains.

## Optimization
zzz is **very** fast. Through a combination of methods, such as allocation at start up and avoiding thread contention, we are able to extract tons of performance.

zzz can be configured to utilize minimal memory while remaining performant. The provided `minram` example only uses 392 kB!

## Features
- Modular Asyncronous Implementation
    - Allows for passing in your own Async implementation.
    - Comes with:
        - io_uring for Linux.
        - IOCP for Windows (planned).
        - kqueue for BSD (planned).
- Modular Protocol Implementation
    - Allows for defining your own Protocol on top of TCP.
    - Comes with:
        - HTTP/1.1
        - MQTT (planned)
        - HTTP/2 (planned)
- TLS using BearSSL
- (Almost) all memory allocated at startup
    - Only allocations happen while storing received data for parsing.


## Platform Support
zzz currently focuses on Linux as the primary platform.

Due to the modular nature, any platform (that works with Zig) can be supported as long as you define an Async backend.


