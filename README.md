# HTTP/2

Pure Crystal implementation of the HTTP/2 protocol.

## Status

- [x] HPACK (including DH compression)
- [x] HTTP/2 connection, streams, frames, ...
- [x] HTTP/2 flow control (in/out, whole-connection, per-stream)
- [ ] HTTP/2 priority
- [x] HTTP/2 server connections
- [x] HTTP/1 to HTTP/2 server connection upgrades
- [ ] Integrate into `HTTP::Server` (WIP in #16)
- [x] HTTP/2 client connections
- [ ] Integrate into `HTTP::Client` (?)
- [x] Passes h2spec 2.6.0 💚

Eventually, adding HTTP/2 support to your HTTP servers written in
Crystal, if they're built on top of `HTTP::Server` or a framework
using `HTTP::Server` internally, shouldn't be more complex than
adding the `http2` shard, and requiring one file:

```crystal
require "http2/server"
```

Only available in #16 for now.

## Tests

Build and run the `bin/server` server, then execute
[h2spec](https://github.com/summerwind/h2spec/releases).

```sh
$ make bin/server CRFLAGS=-Dh2spec
```

Test against HTTP:
```
$ bin/server
$ ./h2spec -p 9292 -S
```

Test against HTTPS:
```sh
$ TLS=true bin/server
$ ./h2spec -p 9292 -k -t -S
```

## RFC

### HTTP/2

- rfc7540 HTTP/2
- rfc7541 HPACK Header Compression for HTTP/2

### HTTP/1

- rfc1945 HTTP/1.0 (informational)
- rfc2616 HTTP/1.1 (obsolete)
- rfc7230 HTTP/1.1 Message Syntax and Routing
- rfc7231 HTTP/1.1 Semantics and Content
- rfc7232 HTTP/1.1 Conditional Requests
- rfc7233 HTTP/1.1 Range Requests
- rfc7234 HTTP/1.1 Caching
- rfc7235 HTTP/1.1 Authentification
