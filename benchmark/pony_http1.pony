actor Main
  new create(env: Env) =>
    let logger = Logger(env)
    let router = recover val
      BasicRouter
        .> get("/", SimpleHandler)
        .> build()
    end
    HTTPServer(env, router, logger, "127.0.0.1", "8081")

class SimpleHandler is RequestHandler
  fun apply(req: Request val, res: ResponseBuilder): ResponseBody iso^ =>
    let body = recover iso String end
    body.append("Hello, World!")
    res.set_status(200)
    res.add_header("Content-Type", "text/plain")
    res.finish(consume body)
