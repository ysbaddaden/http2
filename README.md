# HTTP/2

Pure Crystal implementation of the HTTP/2 protocol.

## Status

- [x] HPACK (including DH compression)
- [x] HTTP/2 connection, streams, frames, ...
- [x] HTTP/2 flow control (in/out, whole-connection, per-stream)
- [x] HTTP/2 server connections
- [x] HTTP/1 to HTTP/2 server connection upgrades
- [x] Integrate into `HTTP::Server`
- [x] HTTP/2 client connections
- [ ] Integrate into `HTTP::Client`
- [x] Passes h2spec 2.6.0 💚

To add HTTP/2 support to your HTTP servers written in Crystal, if they're built
on top of `HTTP::Server` or a framework using `HTTP::Server` internally, add the
`http2` shard to your `shard.yml`, then require one file:

```crystal
require "http2/server"
```

That's it. Now every `HTTP::Server` instance is HTTP/2 compliant! ✨

Well, that's enough for `curl` and other CLI tools, because the HTTP/2 RFC
allows unencrypted HTTP/2 connections, and has multiple ways to upgrade a
HTTP/1 connection into a HTTP/2 connection, but the big browsers (Firefox,
Chrome, Safari) all require a TLS connection... even on localhost. You must
prepare a TLS certificate, instantiate an `OpenSSL::SSL::Context::Server` and
call `HTTP::Server#bind_tls`.

```crystal
context = OpenSSL::SSL::Context::Server.new
context.certificate_chain = File.join(TLS_PATH, "crt.pem")
context.private_key = File.join(TLS_PATH, "key.pem")

server = HTTP::Server.new(handlers)
server.bind_tls(host, port, context)
server.listen
```

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
$ TLS=1 bin/server
$ ./h2spec -p 9292 -k -t -S
```

NOTE: h2spec hasn't been updated since 2020 while a revised version
of the HTTP/2 RFC was released in 2022 (RFC 9113).

## RFC

### HTTP/2

- [RFC 7540](https://datatracker.ietf.org/doc/html/rfc7540) HTTP/2 (obsolete)
- [RFC 7541](https://datatracker.ietf.org/doc/html/rfc7541) HPACK Header Compression for HTTP/2
- [RFC 9113](https://datatracker.ietf.org/doc/html/rfc9113) HTTP/2

### HTTP/1

- [RFC 1945](https://datatracker.ietf.org/doc/html/rfc1945) HTTP/1.0 (informational)
- [RFC 2616](https://datatracker.ietf.org/doc/html/rfc2616) HTTP/1.1 (obsolete)
- [RFC 7230](https://datatracker.ietf.org/doc/html/rfc7230) HTTP/1.1 Message Syntax and Routing (obsolete)
- [RFC 7231](https://datatracker.ietf.org/doc/html/rfc7231) HTTP/1.1 Semantics and Content (obsolete)
- [RFC 7232](https://datatracker.ietf.org/doc/html/rfc7232) HTTP/1.1 Conditional Requests (obsolete)
- [RFC 7233](https://datatracker.ietf.org/doc/html/rfc7233) HTTP/1.1 Range Requests (obsolete)
- [RFC 7234](https://datatracker.ietf.org/doc/html/rfc7234) HTTP/1.1 Caching (obsolete)
- [RFC 7235](https://datatracker.ietf.org/doc/html/rfc7235) HTTP/1.1 Authentification (obsolete)
- [RFC 9112](https://datatracker.ietf.org/doc/html/rfc9112) HTTP/1.1

### HTTP

- [RFC 9110](https://datatracker.ietf.org/doc/html/rfc9110) HTTP semantics
- [RFC 9111](https://datatracker.ietf.org/doc/html/rfc9111) HTTP Caching
