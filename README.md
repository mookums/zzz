# ZZZ

Honestly, this is just me trying out `io_uring`. Maybe this will become something cooler at some point, not 100% sure yet.

It could be pretty cool to have a general single-threaded socket server that can handle various protocols? like maybe raw TCP or HTTP or UDP or etc etc. Could be nice in an embedded context to have a simple way of doing it. Could even have multiple ZZZ instances running at once, each on an individual thread.

For HTTP use, since I hope to use this on my personal website, there's a couple things I'd love to have. They don't need to exist here though.

- Memory Allocated at Start Up
    -> ALL memory should be allocated at start up.
        - this includes every job and etc etc
        - we can use a FixedBufferAllocator where we define the size of the buffer at compile time.

- Upper Bounds
    -> All of our loops should have reasonable upper bounds and should handle fails gracefully.

- Assert
    -> We should include various asserts to ensure that we don't have any bugs.

- Templating Syntax [O(n)]
    -> I enjoyed Askama so maybe something similar.
        -> Substituion
        -> If/Else
        -> Iterate over Slices
    -> Probably not in the scope of including it in this project? Maybe?
    -> Embedding of Templates
    -> Comptime parsing of Template, just plug in your values, generate tiny snippets, and get a []const u8 back.

- HTTP/1.1 Compatibility
    -> Needs to have full compatbility, perhaps this can be modularized in a TCP/HTTP module. This can allow for various modules to be included with zzz, such as UDP or HTTP/2 or MQTT or whatever.
    -> Maybe add keep-alive support?

- Request Router
    -> We need to be able to have a longest prefix route matcher. This should also support filtering by methods.
    -> This will be HTTP module specific.

- Testing Suite
    -> Things like this should really be tested. Modules should have extensive testing to ensure that they parse correctly, interpret correctly and respond correctly.

- openzpi
    -> An automatic OpenAPI Spec generator for Zig.
    -> Basically, generate a file that has all of the OpenAPI information for interacting with a API.
    -> Probably use the stdlib HTTP system? Maybe support custom implementations so anyone can use theirs.
