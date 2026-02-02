use "time"

primitive IndexAppHandler is AppHandler
  fun apply(ctx: AppContext box): HTTPResponse =>
    let html: String val = recover val
      let s = recover iso String end
      s.append("<html><head><title>Pony HTTP Server</title></head><body>")
      s.append("<h1>Pony HTTP Server</h1>")
      s.append("<p>Try these endpoints:</p>")
      s.append("<ul>")
      s.append("<li><a href='/ping'>/ping</a> - Health check</li>")
      s.append("<li><a href='/time'>/time</a> - Unix timestamp</li>")
      s.append("<li><a href='/echo/hello'>/echo/:message</a> - Echo message</li>")
      s.append("</ul>")
      s.append("</body></html>")
      consume val s
    end
    HTTPResponse.ok_html(html)

primitive PingAppHandler is AppHandler
  fun apply(ctx: AppContext box): HTTPResponse =>
    HTTPResponse.ok("PONG")

primitive TimeAppHandler is AppHandler
  fun apply(ctx: AppContext box): HTTPResponse =>
    let now = Time.now()
    HTTPResponse.ok(now._1.string())

primitive EchoParamAppHandler is AppHandler
  fun apply(ctx: AppContext box): HTTPResponse =>
    HTTPResponse.ok(ctx.param("message"))

primitive DefaultPostAppHandler is AppHandler
  fun apply(ctx: AppContext box): HTTPResponse =>
    let body = ctx.body()
    if body.size() > 0 then
      HTTPResponse.ok("Received: " + body)
    else
      HTTPResponse.ok("POST request received")
    end

primitive DefaultPutAppHandler is AppHandler
  fun apply(ctx: AppContext box): HTTPResponse =>
    HTTPResponse.ok("PUT " + ctx.path())

primitive DefaultDeleteAppHandler is AppHandler
  fun apply(ctx: AppContext box): HTTPResponse =>
    HTTPResponse.ok("DELETE " + ctx.path())

// Note: ServerHeaderMiddleware is now defined in middleware.pony
// Use the one from there instead.
