# LastPoint

HTTP/1.1 and HTTP/2 server framework for Pony.

## Features

- **HTTP/1.1** - RFC 9112 compliant with keep-alive, chunked encoding, pipelining
- **HTTP/2** - RFC 7540 compliant (91/92 h2spec tests), multiplexing, flow control, HPACK compression
- **TLS + ALPN** - Automatic protocol negotiation (h2 / http/1.1)
- **Router** - Path parameters (`:id`), wildcards (`*path`), method-based routing
- **Middleware** - CORS, logging, custom headers
- **Static files** - Directory serving with path sanitization

## Quick Start

```pony
primitive HelloHandler is AppHandler
  fun apply(ctx: AppContext box): HTTPResponse =>
    HTTPResponse.ok("Hello " + ctx.param("name"))

actor Main
  new create(env: Env) =>
    let router = recover val
      HttpApp
        .> get("/hello/:name", HelloHandler)
        .> build()
    end
    HTTPServer(env, router, Logger(env), "0.0.0.0", "8080")
```

Build and run:

```bash
# macOS with Homebrew OpenSSL
ponyc -D openssl_3.0.x --linker "ld -L/opt/homebrew/opt/openssl@3/lib -lssl -lcrypto"

# Linux
ponyc -D openssl_3.0.x

./http_server
```

## Router

```pony
HttpApp
  .> get("/", IndexHandler)
  .> get("/users/:id", GetUserHandler)      // path param
  .> post("/users", CreateUserHandler)
  .> get("/assets/*path", StaticHandler)     // wildcard capture
  .> with_middleware(CORSMiddleware)
  .> build()
```

Access parameters in handlers:

```pony
let user_id = ctx.param("id")      // path parameter
let query = ctx.query("search")    // query string
let body = ctx.body_json()         // parsed JSON body
```

## Configuration

```bash
./http_server --host 0.0.0.0 --port 8443 --tls-enabled
```

Environment variables: `HTTP_SERVER_HOST`, `HTTP_SERVER_PORT`, `HTTP_SERVER_TLS_ENABLED`

## Project Structure

| File | Purpose |
|------|---------|
| `http_app.pony` | Framework builder, AppContext, middleware chain |
| `flex_router.pony` | Router with path parameters and wildcards |
| `middleware.pony` | CORS, logging, server header middleware |
| `http2.pony` | HTTP/2 protocol implementation |
| `hpack.pony` | HPACK header compression (RFC 7541) |
| `connection.pony` | HTTP/1.1 connection handler |
| `tls.pony` | TLS/ALPN protocol negotiation |

## Requirements

- Pony compiler 0.60+
- OpenSSL 3.0+

On macOS with Homebrew: `brew install openssl`

## Benchmarks

Performance comparison with Go (Apple Silicon M1, 4 threads, 100 connections):

| Protocol | Pony | Go | vs Go |
|----------|------|-----|-------|
| HTTP/1.1 | 100,426 req/s | 133,126 req/s | 75% |
| HTTP/2 (50cx100s) | 107,705 req/s | 318,109 req/s | 34% |

HTTP/2 tested with `h2load -n100000 -c50 -m100` (50 connections, 100 streams each).

## Test

```bash
# Start server
./http_server

# In another terminal
curl http://localhost:8080/ping    # PONG
curl http://localhost:8080/time    # Unix timestamp
curl http://localhost:8080/echo/hello  # hello
```

## License

MIT
