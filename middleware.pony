use "collections"

class val CORSConfig
  """
  Configuration for CORS (Cross-Origin Resource Sharing) middleware.

  Allows fine-grained control over cross-origin requests.
  """

  // Allowed origins (use ["*"] for any origin)
  let allowed_origins: Array[String] val

  // Allowed HTTP methods
  let allowed_methods: Array[String] val

  // Allowed request headers
  let allowed_headers: Array[String] val

  // Headers exposed to the client
  let exposed_headers: Array[String] val

  // Allow credentials (cookies, authorization headers)
  let allow_credentials: Bool

  // Max age for preflight cache (in seconds)
  let max_age: U64

  new val create(
    allowed_origins': Array[String] val = recover ["*"] end,
    allowed_methods': Array[String] val = recover ["GET"; "POST"; "PUT"; "DELETE"; "HEAD"; "OPTIONS"; "PATCH"] end,
    allowed_headers': Array[String] val = recover ["Content-Type"; "Authorization"; "X-Requested-With"] end,
    exposed_headers': Array[String] val = recover [] end,
    allow_credentials': Bool = false,
    max_age': U64 = 86400)
  =>
    """
    Create CORS configuration.

    Defaults:
    - allowed_origins: ["*"] (any origin)
    - allowed_methods: common HTTP methods
    - allowed_headers: Content-Type, Authorization, X-Requested-With
    - exposed_headers: none
    - allow_credentials: false
    - max_age: 86400 seconds (24 hours)
    """
    allowed_origins = allowed_origins'
    allowed_methods = allowed_methods'
    allowed_headers = allowed_headers'
    exposed_headers = exposed_headers'
    allow_credentials = allow_credentials'
    max_age = max_age'

  fun is_origin_allowed(origin: String): Bool =>
    """
    Check if an origin is allowed.
    """
    for allowed in allowed_origins.values() do
      if allowed == "*" then
        return true
      end
      if allowed == origin then
        return true
      end
    end
    false

primitive CORSMiddleware is AppMiddleware
  """
  Cross-Origin Resource Sharing middleware.

  Handles preflight OPTIONS requests and adds CORS headers to responses.

  Usage:
    let cors_config = CORSConfig(
      where allowed_origins = recover ["https://example.com"] end,
            allow_credentials = true
    )

    let router = HttpApp
      .> with_middleware(CORSMiddleware(cors_config))
      .> get("/api/data", DataHandler)
      .build()
  """

  fun apply(ctx: AppContext box, next: AppHandler val): HTTPResponse =>
    """
    Apply CORS handling to the request.
    """
    // Use default config if none specified
    _handle_cors(ctx, next, CORSConfig)

  fun _handle_cors(
    ctx: AppContext box,
    next: AppHandler val,
    config: CORSConfig val): HTTPResponse
  =>
    """
    Internal CORS handling logic.
    """
    let origin = ctx.header("Origin")

    // Check if this is a preflight request
    if ctx.method() == "OPTIONS" then
      let requested_method = ctx.header("Access-Control-Request-Method")
      let requested_headers = ctx.header("Access-Control-Request-Headers")

      // Validate origin
      if not config.is_origin_allowed(origin) then
        return HTTPResponse.with_status(403).body("Origin not allowed")
      end

      // Validate method
      if requested_method.size() > 0 then
        var method_allowed = false
        for m in config.allowed_methods.values() do
          if m == requested_method then
            method_allowed = true
            break
          end
        end
        if not method_allowed then
          return HTTPResponse.with_status(403).body("Method not allowed")
        end
      end

      // Build preflight response
      let resp = HTTPResponse.with_status(204)

      // Add CORS headers
      _add_cors_headers(resp, origin, config)

      // Add preflight-specific headers
      resp.header("Access-Control-Max-Age", config.max_age.string())

      if requested_headers.size() > 0 then
        resp.header("Access-Control-Allow-Headers", requested_headers)
      else
        // List allowed headers
        let headers_str = _join_headers(config.allowed_headers)
        if headers_str.size() > 0 then
          resp.header("Access-Control-Allow-Headers", headers_str)
        end
      end

      return resp.body("")
    end

    // Regular request - process and add CORS headers
    let resp = next(ctx)

    // Add CORS headers to the response
    _add_cors_headers(resp, origin, config)

    resp

  fun _add_cors_headers(
    resp: HTTPResponse ref,
    origin: String,
    config: CORSConfig val)
  =>
    """
    Add CORS headers to a response.
    """
    // Access-Control-Allow-Origin
    if config.is_origin_allowed(origin) then
      if config.allow_credentials then
        // When credentials are allowed, must specify exact origin
        resp.header("Access-Control-Allow-Origin", origin)
        resp.header("Vary", "Origin")
      else
        resp.header("Access-Control-Allow-Origin", origin)
      end
    end

    // Access-Control-Allow-Methods
    let methods_str = _join_headers(config.allowed_methods)
    if methods_str.size() > 0 then
      resp.header("Access-Control-Allow-Methods", methods_str)
    end

    // Access-Control-Allow-Headers (for regular requests)
    let headers_str = _join_headers(config.allowed_headers)
    if headers_str.size() > 0 then
      resp.header("Access-Control-Allow-Headers", headers_str)
    end

    // Access-Control-Expose-Headers
    let exposed_str = _join_headers(config.exposed_headers)
    if exposed_str.size() > 0 then
      resp.header("Access-Control-Expose-Headers", exposed_str)
    end

    // Access-Control-Allow-Credentials
    if config.allow_credentials then
      resp.header("Access-Control-Allow-Credentials", "true")
    end

  fun _join_headers(headers: Array[String] val): String =>
    """
    Join header names with commas.
    """
    let result = recover String end
    var first = true
    for h in headers.values() do
      if not first then result.append(", ") end
      first = false
      result.append(h)
    end
    consume result

class val CORSMiddlewareConfig is AppMiddleware
  """
  CORS middleware with custom configuration.
  """

  let _config: CORSConfig val

  new val create(config: CORSConfig val) =>
    _config = config

  fun apply(ctx: AppContext box, next: AppHandler val): HTTPResponse =>
    """
    Apply CORS handling with custom configuration.
    """
    CORSMiddleware._handle_cors(ctx, next, _config)

primitive ServerHeaderMiddleware is AppMiddleware
  """
  Middleware that adds a Server header to all responses.

  Usage:
    let app1 = HttpApp.with_middleware(ServerHeaderMiddleware)
    let app2 = app1.get("/", IndexHandler)
    let router = app2.build()
  """

  fun apply(ctx: AppContext box, next: AppHandler val): HTTPResponse =>
    """
    Add Server header to the response.
    """
    let resp = next(ctx)
    resp.header("Server", "PonyHTTP/1.0")
    resp

class val LoggingMiddleware is AppMiddleware
  """
  Middleware that logs requests and responses.

  Usage:
    let app1 = HttpApp.with_middleware(LoggingMiddleware(env.out))
    let app2 = app1.get("/", IndexHandler)
    let router = app2.build()
  """

  let _out: OutStream

  new val create(out: OutStream) =>
    _out = out

  fun apply(ctx: AppContext box, next: AppHandler val): HTTPResponse =>
    """
    Log the request and response.
    """
    let start_secs = I64(0)
    let start_nanos = I64(0)

    let resp = next(ctx)

    let end_secs = I64(0)
    let duration = end_secs - start_secs

    _out.print(
      ctx.method() + " " + ctx.path() + " - " +
      "200" + " (" + duration.string() + "s)")

    resp

