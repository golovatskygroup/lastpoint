use "collections"

primitive _FlexSegKind
  fun literal(): U8 => 0
  fun param(): U8 => 1
  fun wildcard(): U8 => 2

class val _FlexSeg
  let kind: U8
  let text: String val

  new val create(kind': U8, text': String val) =>
    kind = kind'
    text = text'

class val _FlexRoute
  let pattern: String val
  let segments: Array[_FlexSeg val] val
  let handler: AppHandler val

  new val create(pattern': String val, handler': AppHandler val) =>
    pattern = _FlexUtil.normalize_path(pattern')
    segments = _FlexUtil.parse_pattern(pattern)
    handler = handler'

primitive _FlexUtil
  fun normalize_path(path: String val): String val =>
    if path.size() == 0 then
      "/"
    else
      var p: String val = if (try path(0)? == '/' else false end) then path else "/" + path end
      if (p.size() > 1) and (try p(p.size() - 1)? == '/' else false end) then
        recover val p.substring(0, (p.size() - 1).isize()) end
      else
        p
      end
    end

  fun parse_pattern(pattern: String val): Array[_FlexSeg val] val =>
    let norm = normalize_path(pattern)
    let raw_parts = norm.split("/")
    let segs = recover iso Array[_FlexSeg val] end

    for part in (consume raw_parts).values() do
      if part.size() == 0 then
        continue
      end

      try
        if part(0)? == ':' then
          let name = recover val part.substring(1, part.size().isize()) end
          segs.push(_FlexSeg(_FlexSegKind.param(), name))
        elseif part(0)? == '*' then
          let name = if part.size() > 1 then
            recover val part.substring(1, part.size().isize()) end
          else
            "*"
          end
          segs.push(_FlexSeg(_FlexSegKind.wildcard(), name))
        else
          segs.push(_FlexSeg(_FlexSegKind.literal(), part))
        end
      else
        segs.push(_FlexSeg(_FlexSegKind.literal(), part))
      end
    end

    consume val segs

  fun split_path(path: String val): Array[String] =>
    let norm = normalize_path(path)
    let raw_parts = norm.split("/")
    let segs = Array[String]
    for part in (consume raw_parts).values() do
      if part.size() == 0 then
        continue
      end
      segs.push(part)
    end
    segs

class val FlexRouter is RequestRouter
  """
  Parameter-aware router intended for HTTP/2 (but works for HTTP/1.1 too).

  Supported patterns:
  - Literal: `/ping`
  - Param segment: `/users/:id`
  - Wildcard (must be last): `/assets/*path` (captures remainder into `path`)

  Method handling:
  - HEAD falls back to GET route list (response body is cleared)
  - OPTIONS returns 204 + Allow if any route matches the path
  - 405 includes Allow header for matching path
  """

  let _get_routes: Array[_FlexRoute val] val
  let _post_routes: Array[_FlexRoute val] val
  let _put_routes: Array[_FlexRoute val] val
  let _delete_routes: Array[_FlexRoute val] val

  new val create(
    get_routes: Array[_FlexRoute val] val = recover Array[_FlexRoute val] end,
    post_routes: Array[_FlexRoute val] val = recover Array[_FlexRoute val] end,
    put_routes: Array[_FlexRoute val] val = recover Array[_FlexRoute val] end,
    delete_routes: Array[_FlexRoute val] val = recover Array[_FlexRoute val] end)
  =>
    _get_routes = get_routes
    _post_routes = post_routes
    _put_routes = put_routes
    _delete_routes = delete_routes

  fun val add(method: String val, pattern: String val, handler: AppHandler val): FlexRouter val =>
    """
    Register a route for a given method.
    """
    match method
    | "GET" =>
      let routes = recover val
        let arr = Array[_FlexRoute val]
        arr.concat(_get_routes.values())
        arr.push(_FlexRoute(pattern, handler))
        arr
      end
      FlexRouter(consume routes, _post_routes, _put_routes, _delete_routes)
    | "POST" =>
      let routes = recover val
        let arr = Array[_FlexRoute val]
        arr.concat(_post_routes.values())
        arr.push(_FlexRoute(pattern, handler))
        arr
      end
      FlexRouter(_get_routes, consume routes, _put_routes, _delete_routes)
    | "PUT" =>
      let routes = recover val
        let arr = Array[_FlexRoute val]
        arr.concat(_put_routes.values())
        arr.push(_FlexRoute(pattern, handler))
        arr
      end
      FlexRouter(_get_routes, _post_routes, consume routes, _delete_routes)
    | "DELETE" =>
      let routes = recover val
        let arr = Array[_FlexRoute val]
        arr.concat(_delete_routes.values())
        arr.push(_FlexRoute(pattern, handler))
        arr
      end
      FlexRouter(_get_routes, _post_routes, _put_routes, consume routes)
    else
      this
    end

  fun route(req: HTTPRequest): HTTPResponse =>
    let method = req.method()
    let path = req.path()
    let path_segs = _FlexUtil.split_path(path)

    if method == "OPTIONS" then
      let allow = _allow_header(req, path_segs)
      if allow.size() == 0 then
        return HTTPResponse.not_found()
      end
      return HTTPResponse.with_status(204).header("Allow", allow).body("")
    end

    let routes = match method
    | "GET" => _get_routes
    | "POST" => _post_routes
    | "PUT" => _put_routes
    | "DELETE" => _delete_routes
    | "HEAD" => _get_routes
    else
      return HTTPResponse.method_not_allowed()
    end

    for r in routes.values() do
      match _match(req, r, path_segs)
      | let params: Map[String, String] val =>
        let ctx = AppContext(req, params)
        let resp = r.handler(ctx)
        if method == "HEAD" then
          resp.body("")
        end
        return resp
      end
    end

    let allow = _allow_header(req, path_segs)
    if allow.size() > 0 then
      return HTTPResponse.method_not_allowed().header("Allow", allow)
    end

    HTTPResponse.not_found()

  fun _allow_header(req: HTTPRequest, path_segs: Array[String]): String val =>
    let methods = recover iso Array[String] end
    if _any_match(req, _get_routes, path_segs) then methods.push("GET") end
    if _any_match(req, _post_routes, path_segs) then methods.push("POST") end
    if _any_match(req, _put_routes, path_segs) then methods.push("PUT") end
    if _any_match(req, _delete_routes, path_segs) then methods.push("DELETE") end
    if methods.size() == 0 then
      ""
    else
      // HEAD is always allowed when GET exists.
      if not methods.contains("GET") then
        _join_csv(consume methods)
      else
        methods.push("HEAD")
        _join_csv(consume methods)
      end
    end

  fun _join_csv(items: Array[String] iso): String val =>
    let s = recover iso String end
    var first = true
    for item in (consume items).values() do
      if not first then s.append(", ") end
      first = false
      s.append(item)
    end
    consume val s

  fun _any_match(
    req: HTTPRequest,
    routes: Array[_FlexRoute val] val,
    path_segs: Array[String])
    : Bool
  =>
    for r in routes.values() do
      match _match(req, r, path_segs)
      | let _: Map[String, String] val => return true
      end
    end
    false

  fun _match(
    req: HTTPRequest,
    r: _FlexRoute val,
    path_segs: Array[String])
    : (Map[String, String] val | None)
  =>
    let segs = r.segments

    // Wildcard must be last.
    if (segs.size() > 0) and (try segs(segs.size() - 1)?.kind == _FlexSegKind.wildcard() else false end) then
      if path_segs.size() < (segs.size() - 1) then
        return None
      end
    else
      if path_segs.size() != segs.size() then
        return None
      end
    end

    let params = Map[String, String]

    var i: USize = 0
    while i < segs.size() do
      let seg = try segs(i)? else return None end

      if seg.kind == _FlexSegKind.wildcard() then
        // Capture the rest (including current segment) and finish.
        let rest = recover String end
        var j = i
        var first = true
        while j < path_segs.size() do
          if not first then rest.append("/") end
          first = false
          try rest.append(path_segs(j)?) end
          j = j + 1
        end
        params.update(seg.text, req.url_decode(consume rest))
        return _freeze_params(params)
      end

      let part = try path_segs(i)? else return None end
      if seg.kind == _FlexSegKind.literal() then
        if part != seg.text then
          return None
        end
      elseif seg.kind == _FlexSegKind.param() then
        params.update(seg.text, req.url_decode(part))
      else
        return None
      end

      i = i + 1
    end

    _freeze_params(params)

  fun _freeze_params(params: Map[String, String] box): Map[String, String] val =>
    let frozen = recover iso Map[String, String] end
    for (k, v) in params.pairs() do
      frozen.update(k, v)
    end
    consume val frozen
