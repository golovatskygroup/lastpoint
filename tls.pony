use "net"
use "files"
use net_ssl = "net_ssl"

class val TLSConfig
  """
  Configuration for TLS/HTTPS support.

  Handles certificate loading and ALPN (Application-Layer Protocol Negotiation)
  settings for HTTP/2 support.

  Usage:
    // Load from files with HTTP/2 support
    let config = TLSConfig(
      "cert.pem",
      "key.pem",
      ["h2"; "http/1.1"]
    )

    // Or with defaults (HTTP/1.1 only)
    let config = TLSConfig("cert.pem", "key.pem")
  """

  let cert_file: String val
  let key_file: String val
  let alpn_protocols: Array[String] val

  new val create(
    cert_file': String val,
    key_file': String val,
    alpn_protocols': Array[String] val = recover ["http/1.1"] end)
  =>
    """
    Create a TLS configuration.

    Parameters:
    - cert_file': Path to certificate file (PEM format)
    - key_file': Path to private key file (PEM format)
    - alpn_protocols': List of ALPN protocols to negotiate
    """
    cert_file = cert_file'
    key_file = key_file'
    alpn_protocols = alpn_protocols'

  fun alpn_bytes(): Array[U8] val =>
    """
    Build ALPN protocol bytes for OpenSSL.
    Format: length-prefixed protocol names.
    """
    recover
      let result = Array[U8]
      for protocol in alpn_protocols.values() do
        result.push(protocol.size().u8())
        for b in protocol.values() do
          result.push(b)
        end
      end
      result
    end

class TLSServerNotify is TCPListenNotify
  """
  TCP listener notify handler that wraps connections with TLS.
  Performs SSL handshake and ALPN negotiation, then delegates to
  the appropriate protocol handler (HTTP/1.1 or HTTP/2).
  """

  let _env: Env
  let _router: RequestRouter val
  let _logger: Logger
  let _host: String
  let _port: String
  let _tls_config: TLSConfig val
  let _read_timeout: U64
  let _write_timeout: U64
  let _keepalive_timeout: U64
  let _max_body_size: USize
  var _connection_count: USize = 0
  var _ssl_context: (net_ssl.SSLContext | None) = None

  new iso create(
    env: Env,
    router: RequestRouter val,
    logger: Logger,
    host: String,
    port: String,
    tls_config: TLSConfig val,
    read_timeout: U64 = 30,
    write_timeout: U64 = 30,
    keepalive_timeout: U64 = 5,
    max_body_size: USize = 1048576)
  =>
    """
    Create a TLS-enabled server notifier.
    """
    _env = env
    _router = router
    _logger = logger
    _host = host
    _port = port
    _tls_config = tls_config
    _read_timeout = read_timeout
    _write_timeout = write_timeout
    _keepalive_timeout = keepalive_timeout
    _max_body_size = max_body_size

  fun ref listening(listen: TCPListener ref) =>
    """
    Called when server starts listening.
    Initialize SSL context for accepting connections.
    """
    try
      let sslctx = recover
        net_ssl.SSLContext
          .> set_cert(
            FilePath(FileAuth(_env.root), _tls_config.cert_file),
            FilePath(FileAuth(_env.root), _tls_config.key_file))?
      end

      // Set ALPN resolver for protocol negotiation
      sslctx.alpn_set_resolver(net_ssl.ALPNStandardProtocolResolver(_tls_config.alpn_protocols))

      _ssl_context = consume sslctx
      _logger.info("HTTPS server listening on https://" + _host + ":" + _port)
    else
      _logger.log_error("TLS initialization failed: unable to load certificates")
      listen.dispose()
    end

  fun ref not_listening(listen: TCPListener ref) =>
    """
    Called when server fails to bind.
    """
    _env.err.print("Failed to bind to " + _host + ":" + _port)

  fun ref closed(listen: TCPListener ref) =>
    """
    Called when listener is closed.
    """
    _logger.info("HTTPS server stopped")

  fun ref connected(listen: TCPListener ref): TCPConnectionNotify iso^ =>
    """
    Called when a new client connects.
    Creates a TLS connection handler that will perform SSL handshake
    and ALPN negotiation before selecting HTTP/1.1 or HTTP/2 handler.
    """
    _connection_count = _connection_count + 1

    // Create a new SSL connection for this client
    match _ssl_context
    | let sslctx: net_ssl.SSLContext =>
      try
        let ssl = sslctx.server()?
        let protocol_handler = ProtocolSelector(
          _env,
          _router,
          _logger,
          _connection_count,
          _read_timeout,
          _write_timeout,
          _keepalive_timeout,
          _max_body_size
        )
        net_ssl.SSLConnection(consume protocol_handler, consume ssl)
      else
        // SSL setup failed, fallback to HTTP
        _logger.log_error("Failed to create SSL connection, falling back to HTTP")
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
      end
    else
      // No SSL context available, fallback to plain HTTP
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
    end

class ProtocolSelector is (TCPConnectionNotify & net_ssl.ALPNProtocolNotify)
  """
  Handles protocol selection after ALPN negotiation.
  Routes to HTTP/1.1 or HTTP/2 based on negotiated protocol.
  """

  let _env: Env
  let _router: RequestRouter val
  let _logger: Logger
  let _connection_id: USize
  let _read_timeout: U64
  let _write_timeout: U64
  let _keepalive_timeout: U64
  let _max_body_size: USize

  var _delegate: (HTTPConnection | HTTP2Connection | None) = None
  var _alpn_protocol: String = ""
  var _handshake_complete: Bool = false

  new iso create(
    env: Env,
    router: RequestRouter val,
    logger: Logger,
    connection_id: USize,
    read_timeout: U64 = 30,
    write_timeout: U64 = 30,
    keepalive_timeout: U64 = 5,
    max_body_size: USize = 1048576)
  =>
    """
    Create a protocol selector.
    """
    _env = env
    _router = router
    _logger = logger
    _connection_id = connection_id
    _read_timeout = read_timeout
    _write_timeout = write_timeout
    _keepalive_timeout = keepalive_timeout
    _max_body_size = max_body_size

  fun ref alpn_negotiated(conn: TCPConnection, protocol: (net_ssl.ALPNProtocolName | None)) =>
    """
    Called when ALPN negotiation completes.
    Select appropriate protocol handler based on negotiated protocol.
    """
    match protocol
    | let proto: net_ssl.ALPNProtocolName =>
      _alpn_protocol = proto
    end

    _logger.info("TLS ALPN negotiated: " + _alpn_protocol, LogFields(_connection_id))

    // Select protocol handler based on ALPN
    match _alpn_protocol
    | "h2" =>
      _logger.debug("Using HTTP/2 handler", LogFields(_connection_id))
      _delegate = HTTP2Connection(
        _env,
        _router,
        _logger,
        _connection_id,
        _read_timeout,
        _write_timeout,
        _keepalive_timeout,
        _max_body_size
      )
    | "http/1.1" =>
      _logger.debug("Using HTTP/1.1 handler", LogFields(_connection_id))
      _delegate = HTTPConnection(
        _env,
        _router,
        _logger,
        _connection_id,
        _read_timeout,
        _write_timeout,
        _keepalive_timeout,
        _max_body_size
      )
    else
      // No ALPN or unknown protocol - default to HTTP/1.1
      if _alpn_protocol.size() > 0 then
        _logger.warn("Unknown ALPN protocol: " + _alpn_protocol + ", defaulting to HTTP/1.1",
          LogFields(_connection_id))
      else
        _logger.debug("No ALPN protocol negotiated, using HTTP/1.1", LogFields(_connection_id))
      end
      _delegate = HTTPConnection(
        _env,
        _router,
        _logger,
        _connection_id,
        _read_timeout,
        _write_timeout,
        _keepalive_timeout,
        _max_body_size
      )
    end

  fun ref accepted(conn: TCPConnection ref) =>
    """
    Called when connection is accepted (after TLS handshake).
    Delegate to the selected protocol handler.
    """
    _handshake_complete = true
    match _delegate
    | let handler: HTTPConnection ref => handler.accepted(conn)
    | let handler: HTTP2Connection ref => handler.accepted(conn)
    end

  fun ref connected(conn: TCPConnection ref) =>
    """
    Called when connection is established.
    """
    match _delegate
    | let handler: HTTPConnection ref => handler.connected(conn)
    | let handler: HTTP2Connection ref => handler.connected(conn)
    end

  fun ref received(
    conn: TCPConnection ref,
    data: Array[U8] iso,
    times: USize): Bool
  =>
    """
    Pass decrypted data to the protocol handler.
    """
    match _delegate
    | let handler: HTTPConnection ref => handler.received(conn, consume data, times)
    | let handler: HTTP2Connection ref => handler.received(conn, consume data, times)
    else
      // No handler selected yet - buffer data
      true
    end

  fun ref closed(conn: TCPConnection ref) =>
    """
    Forward to protocol handler.
    """
    match _delegate
    | let handler: HTTPConnection ref => handler.closed(conn)
    | let handler: HTTP2Connection ref => handler.closed(conn)
    end

  fun ref connect_failed(conn: TCPConnection ref) =>
    """
    Forward to protocol handler.
    """
    match _delegate
    | let handler: HTTPConnection ref => handler.connect_failed(conn)
    | let handler: HTTP2Connection ref => handler.connect_failed(conn)
    end

  fun ref auth_failed(conn: TCPConnection ref) =>
    """
    Called when SSL authentication fails.
    """
    _logger.log_error("TLS authentication failed", LogFields(_connection_id))

primitive TLSUtil
  """
  Utility functions for TLS operations.
  """

  fun is_tls_enabled(config: Config val): Bool =>
    """
    Check if TLS is enabled in configuration.
    """
    config.tls_enabled and
      (config.tls_cert_file.size() > 0) and
      (config.tls_key_file.size() > 0)

  fun create_tls_config(config: Config val): TLSConfig val =>
    """
    Create TLSConfig from server configuration.
    Default ALPN protocols include "h2" for HTTP/2 support.
    """
    TLSConfig(
      config.tls_cert_file,
      config.tls_key_file,
      recover ["h2"; "http/1.1"] end
    )
