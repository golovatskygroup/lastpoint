use "files"

class val StaticFileHandler is AppHandler
  """
  Handler for serving static files from a directory.

  Features:
  - Directory traversal protection
  - MIME type detection from file extension
  - Index file support (e.g., index.html)
  - Custom cache control headers

  Usage:
    // Serve files from "./public" directory
    let static_handler = StaticFileHandler(
      FileAuth(env.root),
      "./public"
    )

    let router = HttpApp
      .> get("/assets/*path", static_handler)
      .> get("/", static_handler)
      .build()
  """

  let _file_auth: FileAuth val
  let _root_path: String val

  new val create(
    file_auth: FileAuth val,
    root_path: String val)
  =>
    """
    Create a static file handler.

    Parameters:
    - file_auth: File authentication from env.root
    - root_path: Root directory to serve files from
    """
    _file_auth = file_auth
    _root_path = root_path

  fun apply(ctx: AppContext box): HTTPResponse =>
    """
    Handle the request by serving a static file.
    """
    // Get the file path from the wildcard parameter or use root
    let file_path = ctx.param("path")

    // Sanitize and resolve the file path
    let sanitized = _sanitize_path(file_path)
    if sanitized.size() == 0 then
      // Try index file for root path
      return _serve_file(ctx, "index.html")
    end

    // Build full path
    let full_path = _join_paths(_root_path, sanitized)

    // Serve the file
    _serve_file(ctx, full_path)

  fun _sanitize_path(path: String): String =>
    """
    Sanitize the path to prevent directory traversal attacks.
    - Reject paths containing ".."
    - Normalize slashes
    - Remove leading slash
    """
    // Check for directory traversal attempts
    if path.contains("..") then
      return ""
    end

    // Remove leading slash if present
    if (path.size() > 0) and (try path(0)? == '/' else false end) then
      let without_slash = recover val path.substring(1, path.size().isize()) end
      without_slash
    else
      path
    end

  fun _join_paths(a: String, b: String): String =>
    """
    Join two path components.
    """
    if a.size() == 0 then
      b
    elseif b.size() == 0 then
      a
    elseif (try a(a.size() - 1)? == '/' else false end) then
      a + b
    else
      a + "/" + b
    end

  fun _serve_file(ctx: AppContext box, file_path: String): HTTPResponse =>
    """
    Serve a specific file with proper headers.
    """
    // Check if file exists
    let file_fp = FilePath(_file_auth, file_path)
    if not file_fp.exists() then
      return HTTPResponse.not_found()
    end

    // Try to open and read the file
    let file = File.open(file_fp)

    // Get file size
    let size = file.size()

    if size == 0 then
      file.dispose()
      return HTTPResponse.ok("")
    end

    // Read file content
    let content = file.read_string(size)
    file.dispose()

    // Determine MIME type
    let mime_types = MimeTypes
    let mime_type = mime_types.get_mime_type_from_path(file_path)
    let charset = MimeTypes.get_charset(mime_type)

    // Build response with body
    let content_val = recover val consume content end
    let resp = HTTPResponse.ok(consume content_val)

    // Set Content-Type
    if charset.size() > 0 then
      resp.header("Content-Type", mime_type + "; charset=" + charset)
    else
      resp.header("Content-Type", mime_type)
    end

    resp
