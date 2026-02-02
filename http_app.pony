use "collections"

interface val AppHandler
  """
  High-level handler used by the HTTP/2-oriented router/framework.
  """
  fun apply(ctx: AppContext box): HTTPResponse

interface val AppMiddleware
  """
  Middleware that can wrap an `AppHandler`.

  Implementations may:
  - short-circuit by returning a response
  - call `next(ctx)` to continue processing
  - post-process the response returned by `next`
  """
  fun apply(ctx: AppContext box, next: AppHandler val): HTTPResponse

class AppContext
  """
  Per-request context passed to AppHandlers.

  `req` is the underlying parsed request (HTTP/1.1 or HTTP/2-derived).
  `params` contains path parameters extracted from the matched route.
  """

  let req: HTTPRequest
  let params: Map[String, String] val

  new create(req': HTTPRequest, params': Map[String, String] val) =>
    req = req'
    params = params'

  fun method(): String => req.method()
  fun path(): String => req.path()
  fun version(): String => req.version()
  fun body(): String => req.body()

  fun header(name: String): String => req.header(name)
  fun query(name: String): String => req.query(name)

  fun param(name: String): String =>
    try
      params(name)?
    else
      ""
    end

  fun has_param(name: String): Bool =>
    params.contains(name)

  // Request body parsing enhancements for Phase 3

  fun body_json(): (Map[String, String] | None) =>
    """
    Parse request body as JSON.
    Returns a map of the JSON data or None if parsing fails.

    Note: This is a simplified implementation. For full JSON support,
    integrate the pony-json package.
    """
    None  // JSON parsing requires external package

  fun body_form(): Map[String, String] val =>
    """
    Parse application/x-www-form-urlencoded body.
    Returns a map of form field names to values.
    """
    let body_str = req.body()
    if body_str.size() == 0 then
      return recover Map[String, String] end
    end

    let result = Map[String, String]
    let pairs = body_str.split("&")

    for pair_str in (consume pairs).values() do
      if pair_str.size() == 0 then
        continue
      end

      let eq_idx = try pair_str.find("=")? else -1 end
      if eq_idx >= 0 then
        // Use path() as a workaround since substring returns iso
        let key = recover val pair_str.substring(0, eq_idx) end
        let value = recover val pair_str.substring(eq_idx + 1, pair_str.size().isize()) end
        // URL decode the key and value
        result.update(req.url_decode(consume key), req.url_decode(consume value))
      else
        // Key with no value
        result.update(req.url_decode(pair_str), "")
      end
    end

    // Convert to val
    let frozen = recover iso Map[String, String] end
    for (k, v) in result.pairs() do
      frozen.update(k, v)
    end
    consume val frozen

  fun content_type(): String =>
    """
    Get the Content-Type header value (lowercased).
    """
    req.header("Content-Type").lower()

  fun is_json(): Bool =>
    """
    Check if the request has JSON content type.
    """
    content_type().contains("application/json")

  fun is_form(): Bool =>
    """
    Check if the request has form content type.
    """
    let ct = content_type()
    ct.contains("application/x-www-form-urlencoded") or ct.contains("multipart/form-data")

class val _MiddlewareHandler is AppHandler
  let _mw: AppMiddleware val
  let _next: AppHandler val

  new val create(mw: AppMiddleware val, next: AppHandler val) =>
    _mw = mw
    _next = next

  fun apply(ctx: AppContext box): HTTPResponse =>
    _mw.apply(ctx, _next)

class val HttpApp
  """
  Small framework layer on top of `FlexRouter`.

  Note: Cannot use `.>` chaining with val builders as it returns receiver, not result.
  Use explicit variable assignment instead.

  Example:

    let router: RequestRouter val = recover val
      let app1 = HttpApp.with_middleware(MyMiddleware)
      let app2 = app1.get("/users/:id", MyHandler)
      app2.build()
    end
  """

  let _router: FlexRouter val
  let _prefix: String val
  let _middlewares: Array[AppMiddleware val] val

  new val create(
    router: FlexRouter val = FlexRouter,
    prefix: String val = "",
    middlewares: Array[AppMiddleware val] val = recover Array[AppMiddleware val] end)
  =>
    _router = router
    _prefix = prefix
    _middlewares = middlewares

  fun val with_middleware(mw: AppMiddleware val): HttpApp val =>
    let mws = recover val
      let arr = Array[AppMiddleware val]
      arr.concat(_middlewares.values())
      arr.push(mw)
      arr
    end
    HttpApp(_router, _prefix, consume mws)

  fun val scope(prefix: String val): HttpApp val =>
    HttpApp(_router, _join_paths(_prefix, prefix), _middlewares)

  fun val get(pattern: String val, handler: AppHandler val): HttpApp val =>
    _add("GET", pattern, handler)

  fun val post(pattern: String val, handler: AppHandler val): HttpApp val =>
    _add("POST", pattern, handler)

  fun val put(pattern: String val, handler: AppHandler val): HttpApp val =>
    _add("PUT", pattern, handler)

  fun val delete(pattern: String val, handler: AppHandler val): HttpApp val =>
    _add("DELETE", pattern, handler)

  fun val build(): RequestRouter val =>
    _router

  fun val _add(method: String val, pattern: String val, handler: AppHandler val): HttpApp val =>
    let full = _join_paths(_prefix, pattern)
    let composed = _compose(handler)
    HttpApp(_router.add(method, full, composed), _prefix, _middlewares)

  fun val _compose(handler: AppHandler val): AppHandler val =>
    var h: AppHandler val = handler
    var i: ISize = _middlewares.size().isize() - 1
    while i >= 0 do
      try
        let mw = _middlewares(i.usize())?
        h = _MiddlewareHandler(mw, h)
      end
      i = i - 1
    end
    h

  fun val _join_paths(a: String val, b: String val): String val =>
    if a.size() == 0 then
      _normalize_path(b)
    elseif b.size() == 0 then
      _normalize_path(a)
    else
      let left = _normalize_path(a)
      let right = _normalize_path(b)
      if left == "/" then
        right
      elseif right == "/" then
        left
      else
        // Drop trailing "/" from left, ensure right has leading "/".
        let l = if (try left(left.size() - 1)? == '/' else false end) then
          recover val left.substring(0, (left.size() - 1).isize()) end
        else
          left
        end
        let r = if (try right(0)? == '/' else false end) then right else "/" + right end
        l + r
      end
    end

  fun val _normalize_path(p: String val): String val =>
    if p.size() == 0 then
      "/"
    else
      let with_slash = if (try p(0)? == '/' else false end) then p else "/" + p end
      if (with_slash.size() > 1) and (try with_slash(with_slash.size() - 1)? == '/' else false end) then
        recover val with_slash.substring(0, (with_slash.size() - 1).isize()) end
      else
        with_slash
      end
    end
