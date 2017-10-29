# HTTP

A pure Crystal (but incomplete) implementation of the HTTP/2 protocol.

Requires OpenSSL 1.1 or above to support ALPN protocol negotiation, which is
required for HTTP/2 over secure connections.

## TODO

- [x] HPACK (including DH compression)
- [x] HTTP2 connection, streams, ...
- [x] HTTP/2 flow control (using implemented circular buffer)
- [x] support HTTP/2 server connections
- [x] ~~integrate transparently into `HTTP::Server`~~ (broken)
- [ ] ~~integrate into `HTTP::Server::Context` (http version, server-push)~~
- [x] support HTTP/2 client connections
- [ ] ~~integrate into `HTTP::Client`~~

- [x] HPACK tests (HTTP/2 protocol, ...)
- [ ] HTTP/2 server unit tests (HTTP/2 protocol, ...)
- [ ] HTTP/2 client unit tests (HTTP/2 protocol, ...)
- [x] fix failing h2spec tests

## Tests

Build and run the `bin/server` server, then launch
[h2spec](https://github.com/summerwind/h2spec/releases).

```sh
$ make bin/server
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
