use "net"

actor HTTPServer
  """
  HTTP/1.1 and HTTP/2 server implementation using Pony's TCP networking.
  Follows RFC 9112 for HTTP/1.1 message syntax and routing.
  Follows RFC 7540 for HTTP/2 protocol support.
  Supports both HTTP and HTTPS (TLS 1.2 and 1.3).

  HTTP/2 Support:
  - Via ALPN (Application-Layer Protocol Negotiation) over TLS
  - Via HTTP/1.1 Upgrade header (h2c)

  Timeout configuration:
  - read_timeout: Maximum time to wait for request data (default: 30s)
  - write_timeout: Maximum time for sending response (default: 30s)
  - keepalive_timeout: Maximum idle time between requests (default: 5s)

  TLS configuration:
  - tls_config: Optional TLS configuration for HTTPS support
  - ALPN protocols: Configure to include "h2" for HTTP/2 support
  """

  let _env: Env
  let _host: String
  let _port: String
  let _router: RequestRouter val
  let _logger: Logger
  let _read_timeout: U64
  let _write_timeout: U64
  let _keepalive_timeout: U64
  let _max_body_size: USize
  let _tls_config: (TLSConfig val | None)

  new create(
    env: Env,
    router: RequestRouter val,
    logger: Logger,
    host: String = "0.0.0.0",
    port: String = "8080",
    read_timeout: U64 = 30,
    write_timeout: U64 = 30,
    keepalive_timeout: U64 = 5,
    max_body_size: USize = 1048576,
    tls_config: (TLSConfig val | None) = None)
  =>
    """
    Create a new HTTP server.

    Parameters:
    - env: The environment for logging and auth
    - router: The router for handling requests
    - logger: The structured logger for logging
    - host: Host to bind to (default: 0.0.0.0)
    - port: Port to listen on (default: 8080)
    - read_timeout: Timeout for reading request data (default: 30s)
    - write_timeout: Timeout for writing response (default: 30s)
    - keepalive_timeout: Timeout between keep-alive requests (default: 5s)
    - max_body_size: Maximum allowed request body size in bytes (default: 1MB = 1048576)
    - tls_config: Optional TLS configuration for HTTPS (default: None = HTTP only)
    """
    _env = env
    _host = host
    _port = port
    _router = router
    _logger = logger
    _read_timeout = read_timeout
    _write_timeout = write_timeout
    _keepalive_timeout = keepalive_timeout
    _max_body_size = max_body_size
    _tls_config = tls_config

    // Determine if TLS is enabled
    match tls_config
    | let config: TLSConfig val =>
      // TLS enabled - use TLS-wrapped listener
      _logger.info("Starting HTTPS server with TLS and HTTP/2 support")

      // Start TLS-enabled listener with HTTP/2 support
      TCPListener.ip4(
        TCPListenAuth(env.root),
        TLSServerNotify(
          env, router, logger, host, port, config,
          read_timeout, write_timeout, keepalive_timeout, max_body_size
        ),
        host,
        port
      )
    else
      // Plain HTTP (HTTP/1.1 only - HTTP/2 requires TLS with ALPN)
      _logger.info("Starting HTTP server (no TLS, HTTP/1.1 only)")

      TCPListener.ip4(
        TCPListenAuth(env.root),
        HTTPServerNotify(env, router, logger, host, port, read_timeout, write_timeout, keepalive_timeout, max_body_size),
        host,
        port
      )
    end

class HTTPServerNotify is TCPListenNotify
  """
  TCP listen notify handler for the HTTP server.
  Creates new connection handlers for each client.
  """

  let _env: Env
  let _router: RequestRouter val
  let _host: String
  let _port: String
  let _logger: Logger
  let _read_timeout: U64
  let _write_timeout: U64
  let _keepalive_timeout: U64
  let _max_body_size: USize
  var _connection_count: USize = 0

  new iso create(
    env: Env,
    router: RequestRouter val,
    logger: Logger,
    host: String,
    port: String,
    read_timeout: U64 = 30,
    write_timeout: U64 = 30,
    keepalive_timeout: U64 = 5,
    max_body_size: USize = 1048576)
  =>
    _env = env
    _router = router
    _logger = logger
    _host = host
    _port = port
    _read_timeout = read_timeout
    _write_timeout = write_timeout
    _keepalive_timeout = keepalive_timeout
    _max_body_size = max_body_size

  fun ref listening(listen: TCPListener ref) =>
    """
    Called when the server successfully starts listening.
    """
    _logger.info("Server listening on http://" + _host + ":" + _port)

  fun ref not_listening(listen: TCPListener ref) =>
    """
    Called when the server fails to bind to the address.
    """
    _env.err.print("Failed to bind to " + _host + ":" + _port)

  fun ref closed(listen: TCPListener ref) =>
    """
    Called when the listener is closed.
    """
    _logger.info("Server stopped")

  fun ref connected(listen: TCPListener ref): TCPConnectionNotify iso^ =>
    """
    Called when a new client connects.
    Returns a new connection handler with timeout configuration.
    """
    _connection_count = _connection_count + 1
    HTTPConnection(
      _env,
      _router,
      _logger,
      _connection_count,
      _read_timeout,
      _write_timeout,
      _keepalive_timeout,
      _max_body_size
    )
