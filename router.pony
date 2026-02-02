use "collections"
use "time"

interface Handler
  """
  Interface for HTTP request handlers.
  Implementations should process the request and return a response.
  """
  fun apply(req: HTTPRequest): HTTPResponse

class val Route
  """
  Represents a single route with a pattern and handler.
  Immutable (val) so routes can be shared between actors.
  """
  let pattern: String val
  let handler: Handler val
  let has_params: Bool

  new val create(pattern': String val, handler': Handler val) =>
    """
    Create a new route.
    """
    pattern = pattern'
    handler = handler'
    // Check if pattern contains parameters (e.g., /echo/:message)
    has_params = try
      pattern.find(":")? >= 0
    else
      false
    end

class val Router is RequestRouter
  """
  HTTP request router.

  Routes incoming requests to appropriate handlers based on method and path.
  Supports exact path matching and parameterized routes.

  This is a val (immutable) class so it can be safely shared between actors.

  Example usage:
    let router = recover val
      Router
        .> get("/", IndexHandler)
        .> get("/ping", PingHandler)
        .> get("/echo/*", EchoHandler)
    end
  """

  let _get_routes: Array[Route val] val
  let _post_routes: Array[Route val] val
  let _put_routes: Array[Route val] val
  let _delete_routes: Array[Route val] val

  new val create(
    get_routes: Array[Route val] val = recover Array[Route val] end,
    post_routes: Array[Route val] val = recover Array[Route val] end,
    put_routes: Array[Route val] val = recover Array[Route val] end,
    delete_routes: Array[Route val] val = recover Array[Route val] end)
  =>
    """
    Create a new router with the given routes.
    """
    _get_routes = get_routes
    _post_routes = post_routes
    _put_routes = put_routes
    _delete_routes = delete_routes

  // Route registration methods - return a new Router with the added route

  fun val get(pattern: String val, handler: Handler val): Router val =>
    """
    Register a GET route.
    Returns a new Router with the route added.
    """
    let new_routes = recover val
      let arr = Array[Route val]
      arr.concat(_get_routes.values())
      arr.push(Route(pattern, handler))
      arr
    end
    Router(consume new_routes, _post_routes, _put_routes, _delete_routes)

  fun val post(pattern: String val, handler: Handler val): Router val =>
    """
    Register a POST route.
    """
    let new_routes = recover val
      let arr = Array[Route val]
      arr.concat(_post_routes.values())
      arr.push(Route(pattern, handler))
      arr
    end
    Router(_get_routes, consume new_routes, _put_routes, _delete_routes)

  fun val put(pattern: String val, handler: Handler val): Router val =>
    """
    Register a PUT route.
    """
    let new_routes = recover val
      let arr = Array[Route val]
      arr.concat(_put_routes.values())
      arr.push(Route(pattern, handler))
      arr
    end
    Router(_get_routes, _post_routes, consume new_routes, _delete_routes)

  fun val delete(pattern: String val, handler: Handler val): Router val =>
    """
    Register a DELETE route.
    """
    let new_routes = recover val
      let arr = Array[Route val]
      arr.concat(_delete_routes.values())
      arr.push(Route(pattern, handler))
      arr
    end
    Router(_get_routes, _post_routes, _put_routes, consume new_routes)

  // Route matching

  fun route(req: HTTPRequest): HTTPResponse =>
    """
    Route an HTTP request to the appropriate handler.
    Returns the response from the handler or a 404/405 error response.
    """
    let method = req.method()
    let path = req.path()

    // Get the appropriate route list based on method
    let routes = match method
    | "GET" => _get_routes
    | "POST" => _post_routes
    | "PUT" => _put_routes
    | "DELETE" => _delete_routes
    | "HEAD" => _get_routes
    | "OPTIONS" => _get_routes
    else
      // Unknown method - return 405 Method Not Allowed
      return _method_not_allowed()
    end

    // Try to match the path against registered routes
    for r in routes.values() do
      if _match_path(r.pattern, path) then
        return r.handler(req)
      end
    end

    // No route matched - return 404 Not Found
    _not_found()

  fun _match_path(pattern: String val, path: String): Bool =>
    """
    Check if a path matches a pattern.

    Supports:
    - Exact matching: "/ping" matches "/ping"
    - Wildcard prefix: "/echo/*" matches "/echo/hello"
    - Parameter extraction: "/echo/:msg" matches "/echo/hello"
    """
    // Check for wildcard match
    if pattern.size() > 0 then
      // Check if pattern ends with "*" (wildcard)
      if try pattern(pattern.size() - 1)? == '*' else false end then
        let prefix_size = pattern.size() - 1
        let prefix = recover val pattern.substring(0, prefix_size.isize()) end
        return path.compare_sub(consume prefix, prefix_size, 0) == Equal
      end

      // Check for exact match
      if pattern == path then
        return true
      end

      // Check for parameterized route (e.g., /echo/:msg)
      try
        if pattern.find(":")? >= 0 then
          return _match_parameterized(pattern, path)?
        end
      end
    end

    false

  fun _match_parameterized(pattern: String val, path: String): Bool ? =>
    """
    Match a parameterized route pattern against a path.
    """
    // Find the parameter marker
    let colon_idx = pattern.find(":")?
    if colon_idx < 0 then
      return pattern == path
    end

    // Get the prefix before the parameter
    let prefix_size = colon_idx.usize()
    let prefix = recover val pattern.substring(0, colon_idx) end

    // Check if path starts with the prefix
    if path.compare_sub(consume prefix, prefix_size, 0) != Equal then
      return false
    end

    // Check that there's something after the prefix in the path
    if path.size() <= prefix_size then
      return false
    end

    true

  fun _not_found(): HTTPResponse =>
    """
    Return a 404 Not Found response.
    """
    HTTPResponse.not_found()

  fun _method_not_allowed(): HTTPResponse =>
    """
    Return a 405 Method Not Allowed response.
    """
    HTTPResponse.method_not_allowed()

// Built-in handlers - all must be val (immutable)

class IndexHandler is Handler
  """
  Handler for the root path "/".
  Returns a welcome page with navigation links.
  """

  fun apply(req: HTTPRequest): HTTPResponse =>
    let html = recover val
      "<h1>Pony HTTP Server</h1>"
      + "<p>Welcome to the Pony HTTP server!</p>"
      + "<ul>"
      + "<li><a href='/ping'>/ping</a> - Health check</li>"
      + "<li><a href='/time'>/time</a> - Current timestamp</li>"
      + "<li><a href='/echo/hello'>/echo/:message</a> - Echo message</li>"
      + "</ul>"
    end
    HTTPResponse.ok_html(consume html)

class PingHandler is Handler
  """
  Handler for "/ping" - health check endpoint.
  Returns "PONG".
  """

  fun apply(req: HTTPRequest): HTTPResponse =>
    HTTPResponse.ok("PONG")

class TimeHandler is Handler
  """
  Handler for "/time" - returns current Unix timestamp.
  """

  fun apply(req: HTTPRequest): HTTPResponse =>
    let now = Time.now()
    let seconds = now._1
    HTTPResponse.ok(seconds.string())

class EchoHandler is Handler
  """
  Handler for "/echo/:message" - echoes back the message parameter.
  """

  fun apply(req: HTTPRequest): HTTPResponse =>
    let path = req.path()

    // Extract the message from the path
    // Path format: /echo/<message>
    if path.size() > 6 then
      let msg = path.substring(6, path.size().isize())
      HTTPResponse.ok(consume msg)
    else
      HTTPResponse.ok("")
    end

class NotFoundHandler is Handler
  """
  Handler that always returns 404 Not Found.
  """

  fun apply(req: HTTPRequest): HTTPResponse =>
    HTTPResponse.not_found()

class MethodNotAllowedHandler is Handler
  """
  Handler that always returns 405 Method Not Allowed.
  """

  fun apply(req: HTTPRequest): HTTPResponse =>
    HTTPResponse.method_not_allowed()

class DefaultPostHandler is Handler
  """
  Default handler for POST requests.
  Echoes back any body content.
  """

  fun apply(req: HTTPRequest): HTTPResponse =>
    let body = req.body()
    if body.size() > 0 then
      HTTPResponse.ok("Received: " + body)
    else
      HTTPResponse.ok("POST request received")
    end

class DefaultPutHandler is Handler
  """
  Default handler for PUT requests.
  """

  fun apply(req: HTTPRequest): HTTPResponse =>
    HTTPResponse.ok("PUT " + req.path())

class DefaultDeleteHandler is Handler
  """
  Default handler for DELETE requests.
  """

  fun apply(req: HTTPRequest): HTTPResponse =>
    HTTPResponse.ok("DELETE " + req.path())

class DefaultHeadHandler is Handler
  """
  Default handler for HEAD requests.
  Returns same headers as GET but no body.
  """

  fun apply(req: HTTPRequest): HTTPResponse =>
    // HEAD should return same headers as GET but no body
    HTTPResponse.with_status(200)
      .header("Content-Type", "text/plain")
      .body("")

class DefaultOptionsHandler is Handler
  """
  Default handler for OPTIONS requests.
  Returns allowed methods.
  """

  fun apply(req: HTTPRequest): HTTPResponse =>
    HTTPResponse.with_status(200)
      .header("Allow", "GET, POST, PUT, DELETE, HEAD, OPTIONS")
      .body("")
