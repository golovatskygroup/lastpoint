use "net"
use "time"

class HTTPConnection is TCPConnectionNotify
  """
  Handles a single HTTP/1.1 client connection with keep-alive support.
  Implements request parsing and response generation per RFC 9112.
  Supports connection persistence per RFC 9112 Section 9.3.
  Uses Router for request dispatch.

  Timeout handling:
  - read_timeout: Maximum time to wait for request data (idle timeout)
  - write_timeout: Maximum time for sending response (enforced by TCP stack)
  - keepalive_timeout: Maximum idle time between keep-alive requests

  HTTP/2 Support:
  - Detects HTTP/2 connection preface for h2c (cleartext) upgrade
  - Delegates to HTTP2Connection when preface is detected
  """

  let _env: Env
  let _router: RequestRouter val
  let _logger: Logger
  let _id: USize
  embed _buffer: Array[U8] = _buffer.create()
  var _should_close: Bool = false
  var _request_count: USize = 0

  // Security limits
  let _max_buffer_size: USize = 65536  // 64KB max buffer (protects against DoS)
  let _max_body_size: USize             // Max request body size

  // Timeout configuration (in seconds)
  let _read_timeout: U64
  let _write_timeout: U64
  let _keepalive_timeout: U64

  // Activity tracking for timeout enforcement
  var _last_activity: (I64, I64)  // (seconds, nanoseconds) from Time.now()
  var _is_processing_request: Bool = false  // True while actively processing

  // Request timing
  var _request_start_time: (I64, I64) = (0, 0)  // Start time of current request

  // HTTP/2 detection
  var _http2_checked: Bool = false
  var _http2_delegate: (HTTP2Connection | None) = None

  new iso create(
    env: Env,
    router: RequestRouter val,
    logger: Logger,
    id: USize,
    read_timeout: U64 = 30,
    write_timeout: U64 = 30,
    keepalive_timeout: U64 = 5,
    max_body_size: USize = 1048576)
  =>
    """
    Create a new connection handler.

    Parameters:
    - env: The environment for logging
    - router: The router for dispatching requests
    - logger: The structured logger for logging
    - id: Unique connection identifier for debugging
    - read_timeout: Timeout for reading request data (default: 30 seconds)
    - write_timeout: Timeout for writing response (default: 30 seconds)
    - keepalive_timeout: Timeout between keep-alive requests (default: 5 seconds)
    - max_body_size: Maximum allowed request body size in bytes (default: 1MB = 1048576)
    """
    _env = env
    _router = router
    _logger = logger
    _id = id
    _read_timeout = read_timeout
    _write_timeout = write_timeout
    _keepalive_timeout = keepalive_timeout
    _max_body_size = max_body_size
    _last_activity = Time.now()

  fun ref connected(conn: TCPConnection ref) =>
    """
    Called when the TCP connection is established.
    Records initial activity timestamp for timeout tracking.
    """
    _last_activity = Time.now()
    _logger.debug("Connection established", LogFields(_id))

  fun ref received(
    conn: TCPConnection ref,
    data: Array[U8] iso,
    times: USize): Bool
  =>
    """
    Called when data is received from the client.
    Accumulates data until complete HTTP request headers are received.
    Supports pipelined requests and connection keep-alive.

    Timeout checking:
    - If idle for longer than read_timeout, send 408 and close
    - If between requests (keep-alive), use keepalive_timeout
    - Updates last_activity timestamp on valid data receipt

    Returns: true to keep reading, false to stop
    """
    // Check for timeout before processing data
    if _check_timeout(conn) then
      // Timeout occurred, connection has been closed
      return false
    end

    _buffer.append(consume data)

    // Check buffer size limit (security - prevent memory exhaustion)
    if _buffer.size() > _max_buffer_size then
      _logger.warn("Buffer size exceeded, closing connection", LogFields(_id))
      conn.write(_http_error(413, "Payload Too Large", true))
      conn.dispose()
      return false
    end

    // Check for HTTP/2 connection preface (h2c - cleartext HTTP/2)
    // HTTP/2 preface: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" (24 bytes)
    if not _http2_checked then
      // Only mark as checked if we have enough data to determine if it's HTTP/2
      // or if the data clearly doesn't match the preface
      if _buffer.size() >= 24 then
        _http2_checked = true
        // Check if this is an invalid HTTP/2 preface
        // (24 bytes received but don't match the expected preface)
        if not _is_http2_preface() then
          // Check if it could be HTTP/1.1
          if not _is_http1_request() then
            // This looks like an invalid HTTP/2 preface
            // Send GOAWAY and close the connection per RFC 7540 Section 3.5
            _logger.log_error("Invalid HTTP/2 preface received, sending GOAWAY")
            let builder = HTTP2FrameBuilder
            let goaway = builder.build_goaway(0, 0x1)  // PROTOCOL_ERROR
            conn.write(goaway)
            conn.dispose()
            return false
          end
        end
      elseif (_buffer.size() > 0) and not _is_preface_start() then
        _http2_checked = true
      end

      if _is_http2_preface() then
        _logger.info("HTTP/2 connection preface detected, switching to HTTP/2 mode")
        // Create HTTP/2 connection delegate
        let http2 = HTTP2Connection(
          _env,
          _router,
          _logger,
          _id,
          _read_timeout,
          _write_timeout,
          _keepalive_timeout,
          _max_body_size
        )
        _http2_delegate = consume http2
        // Pass all buffered data (including preface) to HTTP/2 handler
        let buffered = _extract_all_buffer()
        match _http2_delegate
        | let h2: HTTP2Connection =>
          return h2.received(conn, consume buffered, times)
        end
        return false
      end
    end

    // Check if we have an HTTP/2 delegate
    match _http2_delegate
    | let http2: HTTP2Connection =>
      let buffered = _extract_all_buffer()
      return http2.received(conn, consume buffered, times)
    end

    // Process all complete requests in buffer (pipelining support)
    while _has_complete_headers() do
      // Mark that we're actively processing a request (prevents timeout)
      _is_processing_request = true

      // Record start time for request duration tracking
      _request_start_time = Time.now()

      _request_count = _request_count + 1

      // Extract the complete request from buffer
      let request_end = _find_request_end()
      if request_end == 0 then
        _is_processing_request = false
        break
      end

      // Extract request data
      let request_data = _extract_request(request_end)

      // Parse and handle the request
      let response = _process_request(consume request_data)

      // Request processing complete, mark as not processing
      _is_processing_request = false

      // Update activity timestamp after successful processing
      _last_activity = Time.now()

      // Send response
      conn.write(response)

      // Check if connection should be closed
      if _should_close then
        conn.dispose()
        return false
      end

      // Continue to next request (pipelining)
    end

    // Update activity timestamp after receiving data
    _last_activity = Time.now()

    // Keep reading for more data
    true

  fun ref closed(conn: TCPConnection ref) =>
    """
    Called when the connection is closed.
    """
    _logger.info("Connection closed", LogFields(_id).with_request_num(_request_count))

  fun ref not_connected(conn: TCPConnection ref) =>
    """
    Called when a connection attempt fails.
    """
    None

  fun ref connect_failed(conn: TCPConnection ref) =>
    """
    Called when a connection attempt fails.
    """
    None

  // Private helper methods

  fun ref _find_request_end(): USize =>
    """
    Find the end of the current HTTP request in the buffer.
    Returns the index after the \r\n\r\n that ends headers.
    """
    if _buffer.size() < 4 then return 0 end
    try
      var i: USize = 0
      let limit = _buffer.size() - 3
      while i < limit do
        if (_buffer(i)? == '\r') and (_buffer(i + 1)? == '\n') and
           (_buffer(i + 2)? == '\r') and (_buffer(i + 3)? == '\n') then
          return i + 4
        end
        i = i + 1
      end
    end
    0

  fun ref _has_complete_headers(): Bool =>
    """
    Check if the buffer contains a complete HTTP request header section.
    Headers end with \r\n\r\n per RFC 9112 Section 2.1.
    """
    _find_request_end() > 0

  fun ref _extract_request(end_idx: USize): Array[U8] iso^ =>
    """
    Extract request data up to end_idx from buffer.
    Removes extracted data from buffer.
    """
    let result = recover Array[U8] end
    result.reserve(end_idx)

    var i: USize = 0
    while i < end_idx do
      try
        result.push(_buffer(0)?)
        _buffer.remove(0, 1)
      end
      i = i + 1
    end

    consume result

  fun ref _process_request(request_data_iso: Array[U8] iso): String =>
    """
    Parse the HTTP request and generate an appropriate response.
    Handles keep-alive logic per RFC 9112 Section 9.3.
    Uses Router for dispatch.
    Supports chunked transfer encoding per RFC 9112 Section 7.1.
    """
    let request_data = _bytes_to_string(consume request_data_iso)

    // Check for Transfer-Encoding: chunked
    let is_chunked = _is_chunked_encoding(request_data)

    if is_chunked then
      // For chunked requests, body size is determined by chunk sizes
      // We'll validate during parsing
      _logger.debug("Processing chunked request", LogFields(_id).with_request_num(_request_count))
    else
      // Check Content-Length header before parsing to catch body size violations early
      let content_length = _extract_content_length(request_data)
      if content_length > _max_body_size then
        _should_close = true
        _logger.warn(
          "Content-Length exceeds limit",
          LogFields(_id)
            .with_request_num(_request_count)
            .with_status_code(413))
        return _http_error(413, "Payload Too Large", true)
      end
    end

    // Parse request using HTTPRequest class with max body size limit
    let req = try
      HTTPRequest.parse(consume request_data, _max_body_size)?
    else
      // Parse error - log internally, return generic error to client
      _should_close = true
      // Note: req is not available here since parsing failed
      // Log generic parse error
      _logger.warn(
        "Failed to parse HTTP request",
        LogFields(_id).with_request_num(_request_count))

      // Generic 400 for parse errors
      return _http_error(400, "Bad Request", true)
    end

    // Route request using the Router
    let response = _router.route(req)

    // Calculate request duration
    let end_time = Time.now()
    let duration_micros = _elapsed_microseconds(_request_start_time, end_time)

    // Log request with all contextual fields
    _logger.info(
      "Request processed",
      LogFields(_id)
        .with_request_num(_request_count)
        .with_method(req.method())
        .with_path(req.path())
        .with_status_code(response.status_code())
        .with_duration_micros(duration_micros))

    // Check Connection header for keep-alive decision
    // RFC 9112 Section 9.3: HTTP/1.1 defaults to persistent connections
    let conn_header = req.header("CONNECTION")
    if (conn_header == "close") then
      _should_close = true
    end

    // Set connection header based on keep-alive decision
    response.connection(_should_close)

    // Convert HTTPResponse to String
    response.render()

  fun ref _bytes_to_string(data: Array[U8] box): String =>
    """
    Convert byte array to string.
    """
    let s = recover String end
    for b in data.values() do
      s.push(b)
    end
    consume s

  fun _extract_content_length(request_data: String): USize =>
    """
    Extract Content-Length value from request headers.
    Returns 0 if not found or invalid.
    """
    // Find Content-Length header (case-insensitive)
    let lower_data = request_data.lower()
    let cl_header = "content-length:"
    let cl_pos = try lower_data.find(cl_header)? else -1 end

    if cl_pos < 0 then
      return 0
    end

    // Find the end of the header line
    let line_start = cl_pos + cl_header.size().isize()
    let line_end = try lower_data.find("\r\n", line_start)? else -1 end

    if line_end < 0 then
      return 0
    end

    // Extract the value
    let value = request_data.substring(line_start, line_end)
    let trimmed = _trim_whitespace(consume value)

    // Parse as integer
    try
      trimmed.usize()?
    else
      0
    end

  fun _is_chunked_encoding(request_data: String): Bool =>
    """
    Check if request uses chunked transfer encoding.
    Returns true if Transfer-Encoding header contains 'chunked'.
    """
    let lower_data = request_data.lower()
    let te_header = "transfer-encoding:"
    let te_pos = try lower_data.find(te_header)? else -1 end

    if te_pos < 0 then
      return false
    end

    // Find the end of the header line
    let line_start = te_pos + te_header.size().isize()
    let line_end = try lower_data.find("\r\n", line_start)? else -1 end

    if line_end < 0 then
      return false
    end

    // Extract and check the value
    let value = request_data.substring(line_start, line_end)
    let trimmed = _trim_whitespace(consume value)
    trimmed.lower().contains("chunked")

  fun _trim_whitespace(s: String): String =>
    """
    Trim leading and trailing whitespace.
    """
    var start: ISize = 0
    let len = s.size().isize()
    var end_idx = len - 1

    // Trim leading whitespace
    while start < len do
      try
        let c = s(start.usize())?
        if (c == ' ') or (c == '\t') then
          start = start + 1
        else
          break
        end
      else
        break
      end
    end

    // Trim trailing whitespace
    while end_idx >= start do
      try
        let c = s(end_idx.usize())?
        if (c == ' ') or (c == '\t') then
          end_idx = end_idx - 1
        else
          break
        end
      else
        break
      end
    end

    if start > end_idx then
      ""
    else
      s.substring(start, end_idx + 1)
    end

  // Response builders (fallback for errors before routing)

  fun ref _http_error(status: U32, phrase: String, close: Bool): String =>
    """
    Build an error response.
    """
    _should_close = close
    let body = recover val
      "<html><body><h1>" + status.string() + "</h1><p>" + phrase + "</p></body></html>"
    end
    let content_len = body.size()
    let conn = if close then "close" else "keep-alive" end
    recover val
      "HTTP/1.1 " + status.string() + " " + phrase + "\r\n"
        + "Content-Type: text/html\r\n"
        + "Content-Length: " + content_len.string() + "\r\n"
        + "Connection: " + conn + "\r\n"
        + "\r\n"
        + consume body
    end

  // Timeout handling methods

  fun ref _check_timeout(conn: TCPConnection ref): Bool =>
    """
    Check if the connection has timed out based on last activity.

    Returns: true if timeout occurred and connection was closed,
             false if connection is still valid

    Timeout logic:
    - If actively processing a request: never timeout
    - If first request (no requests yet): use read_timeout
    - If keep-alive waiting: use keepalive_timeout
    """
    // Never timeout while actively processing a request
    if _is_processing_request then
      return false
    end

    let now = Time.now()
    let elapsed = _elapsed_seconds(_last_activity, now)

    // Determine which timeout to apply
    let timeout_limit = if _request_count == 0 then
      // Waiting for first request - use read timeout
      _read_timeout
    else
      // Waiting between requests - use keepalive timeout
      _keepalive_timeout
    end

    // Check if timeout exceeded
    if elapsed >= timeout_limit then
      _handle_timeout(conn, elapsed, timeout_limit)
      return true
    end

    false

  fun _elapsed_seconds(start: (I64, I64), end': (I64, I64)): U64 =>
    """
    Calculate elapsed seconds between two Time.now() timestamps.
    Handles nanosecond wraparound correctly.
    """
    let start_secs = start._1
    let start_nanos = start._2
    let end_secs = end'._1
    let end_nanos = end'._2

    if end_secs < start_secs then
      // Clock went backwards (shouldn't happen, but handle gracefully)
      return 0
    elseif end_secs == start_secs then
      // Same second, check nanoseconds
      if end_nanos >= start_nanos then
        return 0  // Less than a second elapsed
      else
        return 0  // Nanosecond wraparound within same second
      end
    else
      // Different seconds
      var secs = end_secs - start_secs

      // Adjust for nanoseconds
      if end_nanos < start_nanos then
        // Borrow a second for nanoseconds
        secs = secs - 1
      end

      secs.u64()
    end

  fun _elapsed_microseconds(start: (I64, I64), end': (I64, I64)): U64 =>
    """
    Calculate elapsed microseconds between two Time.now() timestamps.
    """
    let start_secs = start._1
    let start_nanos = start._2
    let end_secs = end'._1
    let end_nanos = end'._2

    if end_secs < start_secs then
      // Clock went backwards (shouldn't happen, but handle gracefully)
      return 0
    elseif end_secs == start_secs then
      // Same second
      if end_nanos >= start_nanos then
        return ((end_nanos - start_nanos) / 1000).u64()
      else
        return 0  // Nanosecond wraparound within same second
      end
    else
      // Different seconds
      var secs = end_secs - start_secs
      var nanos = end_nanos - start_nanos

      // Adjust for nanoseconds
      if nanos < 0 then
        // Borrow a second for nanoseconds
        secs = secs - 1
        nanos = nanos + 1_000_000_000
      end

      (secs * 1_000_000).u64() + (nanos / 1000).u64()
    end

  fun ref _handle_timeout(conn: TCPConnection ref, elapsed: U64, limit: U64) =>
    """
    Handle a timeout condition by logging and closing the connection.
    Optionally sends a 408 Request Timeout response if appropriate.
    """
    let timeout_type = if _request_count == 0 then
      "read timeout"
    else
      "keepalive timeout"
    end

    _logger.warn(
      timeout_type + " exceeded, closing connection",
      LogFields(_id)
        .with_request_num(_request_count))

    // Send 408 Request Timeout if we haven't sent any response yet
    // (only for read timeout on first request)
    if _request_count == 0 then
      let timeout_response = _http_error(408, "Request Timeout", true)
      conn.write(timeout_response)
    end

    // Close the connection cleanly
    _should_close = true
    conn.dispose()

  fun ref _is_preface_start(): Bool =>
    """
    Check if the buffer starts with the beginning of HTTP/2 preface ("PRI").
    This is used to determine if we need to wait for more data.
    """
    if _buffer.size() == 0 then
      return false
    end

    // HTTP/2 preface starts with "PRI"
    let preface_start = [as U8: 'P'; 'R'; 'I']

    var i: USize = 0
    while (i < _buffer.size()) and (i < 3) do
      try
        if _buffer(i)? != preface_start(i)? then
          return false
        end
      else
        return false
      end
      i = i + 1
    end
    true

  fun ref _is_http1_request(): Bool =>
    """
    Check if the buffer contains what looks like an HTTP/1.1 request.
    HTTP/1.1 requests start with a method like GET, POST, PUT, DELETE, etc.
    """
    if _buffer.size() < 4 then
      return false
    end

    // Common HTTP/1.1 methods
    try
      let c1 = _buffer(0)?
      let c2 = _buffer(1)?
      let c3 = _buffer(2)?

      // GET, PUT
      if (c1 == 'G') and (c2 == 'E') and (c3 == 'T') then return true end
      if (c1 == 'P') and (c2 == 'U') and (c3 == 'T') then return true end

      // POST
      if _buffer.size() >= 5 then
        let c4 = _buffer(3)?
        if (c1 == 'P') and (c2 == 'O') and (c3 == 'S') and (c4 == 'T') then return true end
      end

      // DELETE
      if _buffer.size() >= 7 then
        let c4 = _buffer(3)?
        let c5 = _buffer(4)?
        let c6 = _buffer(5)?
        if (c1 == 'D') and (c2 == 'E') and (c3 == 'L') and
           (c4 == 'E') and (c5 == 'T') and (c6 == 'E') then return true end
      end

      // HEAD
      if _buffer.size() >= 5 then
        let c4 = _buffer(3)?
        if (c1 == 'H') and (c2 == 'E') and (c3 == 'A') and (c4 == 'D') then return true end
      end

      // OPTIONS
      if _buffer.size() >= 8 then
        let c4 = _buffer(3)?
        let c5 = _buffer(4)?
        let c6 = _buffer(5)?
        let c7 = _buffer(6)?
        if (c1 == 'O') and (c2 == 'P') and (c3 == 'T') and (c4 == 'I') and
           (c5 == 'O') and (c6 == 'N') and (c7 == 'S') then return true end
      end

      // PATCH
      if _buffer.size() >= 6 then
        let c4 = _buffer(3)?
        let c5 = _buffer(4)?
        if (c1 == 'P') and (c2 == 'A') and (c3 == 'T') and (c4 == 'C') and (c5 == 'H') then
          return true
        end
      end
    end

    false

  fun ref _is_http2_preface(): Bool =>
    """
    Check if the buffer contains the HTTP/2 connection preface.
    HTTP/2 preface: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" (24 bytes)
    """
    if _buffer.size() < 24 then
      return false
    end

    let preface = [as U8:
      'P'; 'R'; 'I'; ' '; '*'; ' '; 'H'; 'T'; 'T'; 'P'; '/'; '2'; '.'; '0'; '\r'; '\n'
      '\r'; '\n'; 'S'; 'M'; '\r'; '\n'; '\r'; '\n'
    ]

    var i: USize = 0
    while i < 24 do
      try
        if _buffer(i)? != preface(i)? then
          return false
        end
      else
        return false
      end
      i = i + 1
    end
    true

  fun ref _extract_all_buffer(): Array[U8] iso^ =>
    """
    Extract all data from the buffer.
    Used to pass buffered data to HTTP/2 handler.
    """
    let result = recover Array[U8] end
    result.reserve(_buffer.size())
    for b in _buffer.values() do
      result.push(b)
    end
    _buffer.clear()
    consume result
