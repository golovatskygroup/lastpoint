interface val RequestRouter
  """
  Minimal router interface shared by HTTP/1.1 and HTTP/2 paths.

  Must be `val` so it can be safely shared between actors.
  """
  fun route(req: HTTPRequest): HTTPResponse

