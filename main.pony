use "net"

actor Main
  """
  Entry point for the Pony HTTP/1.1 server.

  Usage:
    ./http_server [options]

  Configuration Sources (in order of precedence):
    1. Environment variables (highest priority)
    2. Command line arguments
    3. Configuration file
    4. Default values (lowest priority)

  Options:
    --config <path>               - Path to JSON configuration file
    --host <host>                 - Host to bind to (default: 0.0.0.0)
    --port <port>                 - Port to listen on (default: 8080)
    --tls-enabled                 - Enable TLS/HTTPS
    --tls-cert-file <path>        - Path to TLS certificate file
    --tls-key-file <path>         - Path to TLS private key file
    --max-body-size <bytes>       - Maximum request body size (default: 1048576 = 1MB)
    --max-headers-size <bytes>    - Maximum headers size (default: 16384)
    --timeout <seconds>           - Request timeout in seconds (default: 30)
    --log-level <level>           - Log level: debug, info, warn, error (default: info)
    --log-format <format>         - Log format: text, json (default: text)
    --read-timeout <seconds>      - Deprecated: use --timeout instead
    --keepalive-timeout <seconds> - Deprecated: use --timeout instead
    --help                        - Show this help message

  Environment Variables:
    HTTP_SERVER_HOST              - Server host
    HTTP_SERVER_PORT              - Server port
    HTTP_SERVER_TLS_ENABLED       - Enable TLS (true/false)
    HTTP_SERVER_TLS_CERT_FILE     - TLS certificate file path
    HTTP_SERVER_TLS_KEY_FILE      - TLS private key file path
    HTTP_SERVER_MAX_BODY_SIZE     - Maximum body size in bytes
    HTTP_SERVER_MAX_HEADERS_SIZE  - Maximum headers size in bytes
    HTTP_SERVER_TIMEOUT_SECONDS   - Timeout in seconds
    HTTP_SERVER_LOG_LEVEL         - Log level
    HTTP_SERVER_LOG_FORMAT        - Log format

  Configuration File (JSON format):
    {
      "server": {
        "host": "0.0.0.0",
        "port": "8080",
        "tls": {
          "enabled": false,
          "cert_file": "",
          "key_file": "",
          "min_version": "1.2",
          "max_version": "1.3",
          "alpn_protocols": ["h2", "http/1.1"]
        }
      },
      "limits": {
        "max_body_size": 1048576,
        "max_headers_size": 16384,
        "timeout_seconds": 30
      },
      "logging": {
        "level": "info",
        "format": "text"
      }
    }

  Examples:
    ./http_server
    ./http_server --host 0.0.0.0 --port 8080
    ./http_server --config server.json
    ./http_server --log-level debug --log-format json
    HTTP_SERVER_PORT=9000 ./http_server

  Endpoints:
    GET  /          - Welcome page with navigation links
    GET  /ping      - Returns "PONG" (health check)
    GET  /time      - Returns current Unix timestamp
    GET  /echo/:msg - Echoes back the message parameter
    POST /          - Echoes back any body content
    PUT  /          - Returns "PUT /"
    DELETE /        - Returns "DELETE /"
  """

  new create(env: Env) =>
    """
    Parse configuration from all sources, create the logger and router,
    and start the HTTP server.
    """
    // Main entry point

    // Check for --help first
    for arg in env.args.values() do
      if arg == "--help" then
        _print_help(env)
        return
      end
    end

    // Load configuration from all sources
    let config = match ConfigLoader.load(env, env.args)
    | let c: Config val =>
      c
    | let err: String =>
      env.err.print("Configuration error: " + err)
      env.err.print("Use --help for usage information")
      return
    end

    // Convert log level string to LogLevel type
    let log_level = _parse_log_level(config.log_level)

    // Convert log format string to LogFormat type
    let log_format = _parse_log_format(config.log_format)

    // Create the structured logger
    let logger = Logger(env, log_level, log_format)

    // Create and configure router with all endpoints
    // Note: Cannot use .> chaining with val builders as it returns receiver, not result
    let router: RequestRouter val = recover val
      let app1 = HttpApp.with_middleware(ServerHeaderMiddleware)
      let app2 = app1.get("/", IndexAppHandler)
      let app3 = app2.get("/ping", PingAppHandler)
      let app4 = app3.get("/time", TimeAppHandler)
      let app5 = app4.get("/echo/:message", EchoParamAppHandler)
      let app6 = app5.post("/", DefaultPostAppHandler)
      let app7 = app6.put("/", DefaultPutAppHandler)
      let app8 = app7.delete("/", DefaultDeleteAppHandler)
      app8.build()
    end

    // Log startup
    logger.info("Starting Pony HTTP/1.1 Server")
    logger.info("Configuration loaded:")
    logger.info("  host=" + config.host + " port=" + config.port)
    logger.info("  tls_enabled=" + config.tls_enabled.string())
    if config.tls_enabled then
      logger.info("  tls_cert_file=" + config.tls_cert_file)
      logger.info("  tls_key_file=" + config.tls_key_file)
    end
    logger.info("  max_body_size=" + config.max_body_size.string() +
      " max_headers_size=" + config.max_headers_size.string())
    logger.info("  timeout_seconds=" + config.timeout_seconds.string())
    logger.info("  log_level=" + config.log_level + " log_format=" + config.log_format)
    logger.info("Routes registered:")
    logger.info("  GET  /          -> IndexHandler")
    logger.info("  GET  /ping      -> PingHandler")
    logger.info("  GET  /time      -> TimeHandler")
    logger.info("  GET  /echo/*    -> EchoHandler")
    logger.info("  POST /          -> DefaultPostHandler")
    logger.info("  PUT  /          -> DefaultPutHandler")
    logger.info("  DELETE /        -> DefaultDeleteHandler")

    // Create TLS config if enabled
    let tls_config = if TLSUtil.is_tls_enabled(config) then
      TLSUtil.create_tls_config(config)
    else
      None
    end

    // Start the HTTP server with configuration
    // Note: timeout_seconds is used for both read and write timeouts
    // keepalive_timeout defaults to 5 seconds (not exposed in config yet)
    HTTPServer(
      env,
      router,
      logger,
      config.host,
      config.port,
      config.timeout_seconds.u64(),
      config.timeout_seconds.u64(),
      5,  // keepalive_timeout - keeping backward compatibility
      config.max_body_size,
      tls_config
    )

    // The server runs in the background via TCPListener
    // Main actor keeps the program alive

  fun _parse_log_level(level_str: String): LogLevel =>
    """
    Convert log level string to LogLevel type.
    """
    match level_str
    | "debug" => LogLevelDebug
    | "info" => LogLevelInfo
    | "warn" => LogLevelWarn
    | "error" => LogLevelError
    else
      LogLevelInfo
    end

  fun _parse_log_format(format_str: String): LogFormat =>
    """
    Convert log format string to LogFormat type.
    """
    match format_str
    | "json" => LogFormatJSON
    else
      LogFormatText
    end

  fun _print_help(env: Env) =>
    """
    Print usage help message.
    """
    env.out.print("Pony HTTP/1.1 Server")
    env.out.print("")
    env.out.print("Usage: ./http_server [options]")
    env.out.print("")
    env.out.print("Configuration Sources (in order of precedence):")
    env.out.print("  1. Environment variables (highest priority)")
    env.out.print("  2. Command line arguments")
    env.out.print("  3. Configuration file")
    env.out.print("  4. Default values (lowest priority)")
    env.out.print("")
    env.out.print("Options:")
    env.out.print("  --config <path>               - Path to JSON configuration file")
    env.out.print("  --host <host>                 - Host to bind to (default: 0.0.0.0)")
    env.out.print("  --port <port>                 - Port to listen on (default: 8080)")
    env.out.print("  --tls-enabled                 - Enable TLS/HTTPS")
    env.out.print("  --tls-cert-file <path>        - Path to TLS certificate file")
    env.out.print("  --tls-key-file <path>         - Path to TLS private key file")
    env.out.print("  --max-body-size <bytes>       - Maximum request body size (default: 1048576 = 1MB)")
    env.out.print("  --max-headers-size <bytes>    - Maximum headers size (default: 16384)")
    env.out.print("  --timeout <seconds>           - Request timeout in seconds (default: 30)")
    env.out.print("  --log-level <level>           - Log level: debug, info, warn, error (default: info)")
    env.out.print("  --log-format <format>         - Log format: text, json (default: text)")
    env.out.print("  --read-timeout <seconds>      - Deprecated: use --timeout instead")
    env.out.print("  --keepalive-timeout <seconds> - Deprecated: use --timeout instead")
    env.out.print("  --help                        - Show this help message")
    env.out.print("")
    env.out.print("Environment Variables:")
    env.out.print("  HTTP_SERVER_HOST              - Server host")
    env.out.print("  HTTP_SERVER_PORT              - Server port")
    env.out.print("  HTTP_SERVER_TLS_ENABLED       - Enable TLS (true/false)")
    env.out.print("  HTTP_SERVER_TLS_CERT_FILE     - TLS certificate file path")
    env.out.print("  HTTP_SERVER_TLS_KEY_FILE      - TLS private key file path")
    env.out.print("  HTTP_SERVER_MAX_BODY_SIZE     - Maximum body size in bytes")
    env.out.print("  HTTP_SERVER_MAX_HEADERS_SIZE  - Maximum headers size in bytes")
    env.out.print("  HTTP_SERVER_TIMEOUT_SECONDS   - Timeout in seconds")
    env.out.print("  HTTP_SERVER_LOG_LEVEL         - Log level")
    env.out.print("  HTTP_SERVER_LOG_FORMAT        - Log format")
    env.out.print("")
    env.out.print("Configuration File (JSON format):")
    env.out.print("  {")
    env.out.print("    \"server\": {")
    env.out.print("      \"host\": \"0.0.0.0\",")
    env.out.print("      \"port\": \"8080\",")
    env.out.print("      \"tls\": {")
    env.out.print("        \"enabled\": false,")
    env.out.print("        \"cert_file\": \"\",")
    env.out.print("        \"key_file\": \"\"")
    env.out.print("      }")
    env.out.print("    },")
    env.out.print("    \"limits\": {")
    env.out.print("      \"max_body_size\": 1048576,")
    env.out.print("      \"max_headers_size\": 16384,")
    env.out.print("      \"timeout_seconds\": 30")
    env.out.print("    },")
    env.out.print("    \"logging\": {")
    env.out.print("      \"level\": \"info\",")
    env.out.print("      \"format\": \"text\"")
    env.out.print("    }")
    env.out.print("  }")
    env.out.print("")
    env.out.print("Examples:")
    env.out.print("  ./http_server")
    env.out.print("  ./http_server --host 0.0.0.0 --port 8080")
    env.out.print("  ./http_server --config server.json")
    env.out.print("  ./http_server --log-level debug --log-format json")
    env.out.print("  HTTP_SERVER_PORT=9000 ./http_server")
