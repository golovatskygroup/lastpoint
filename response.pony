use "time"
use "collections"

class HTTPResponse
  """
  HTTP/1.1 response builder.

  Implements response format per RFC 9112 Section 4:
  status-line = HTTP-version SP status-code SP [ reason-phrase ] CRLF
  *( header-field CRLF )
  CRLF
  [ message-body ]
  """

  var _version: String = "HTTP/1.1"
  var _status_code: U32 = 200
  var _reason_phrase: String = "OK"
  var _headers: Map[String, String] = Map[String, String]
  var _body: String = ""
  var _body_set: Bool = false
  var _chunked: Bool = false
  var _chunks: Array[(String | None)] = Array[(String | None)]  // None = flush marker

  new create() =>
    """
    Create a new HTTP response with default 200 OK status.
    """
    // Add default headers
    _headers.update("Connection", "close")

  new with_status(code: U32) =>
    """
    Create a new HTTP response with the specified status code.
    """
    _status_code = code
    _reason_phrase = _default_reason_phrase(code)
    _headers.update("Connection", "close")

  // Builder methods

  fun ref status(code: U32): HTTPResponse ref =>
    """
    Set the HTTP status code.
    Automatically sets the reason phrase based on standard codes.
    """
    _status_code = code
    _reason_phrase = _default_reason_phrase(code)
    this

  fun ref reason(phrase: String): HTTPResponse ref =>
    """
    Set a custom reason phrase for the status code.
    """
    _reason_phrase = phrase
    this

  fun ref header(name: String, value: String): HTTPResponse ref =>
    """
    Add or update a response header.
    Header names are case-insensitive and stored as provided.
    """
    _headers.update(name, value)
    this

  fun ref body(data: String): HTTPResponse ref =>
    """
    Set the response body content.
    Automatically sets Content-Length header.
    """
    _body = data
    _body_set = true
    _headers.update("Content-Length", data.size().string())
    this

  fun get_body(): String =>
    """
    Get the response body content.
    """
    _body

  fun get_headers(): this->Map[String, String] =>
    """
    Get the response headers map.
    """
    _headers

  fun ref html(content: String): HTTPResponse ref =>
    """
    Set HTML content type and body.
    Automatically sets Content-Length header.
    """
    _headers.update("Content-Type", "text/html; charset=utf-8")
    _body = content
    _body_set = true
    _headers.update("Content-Length", content.size().string())
    this

  fun ref text(content: String): HTTPResponse ref =>
    """
    Set plain text content type and body.
    Automatically sets Content-Length header.
    """
    _headers.update("Content-Type", "text/plain; charset=utf-8")
    _body = content
    _body_set = true
    _headers.update("Content-Length", content.size().string())
    this

  fun ref json(content: String): HTTPResponse ref =>
    """
    Set JSON content type and body.
    Automatically sets Content-Length header.
    """
    _headers.update("Content-Type", "application/json")
    _body = content
    _body_set = true
    _headers.update("Content-Length", content.size().string())
    this

  fun ref file(content: String, filename: String): HTTPResponse ref =>
    """
    Set body with automatic Content-Type detection from filename extension.
    Automatically sets Content-Length header.

    Uses MimeTypes to determine the appropriate Content-Type based on
    the file extension. Falls back to "application/octet-stream" for
    unknown extensions per RFC 2045.

    Examples:
    - file(html_content, "index.html") sets Content-Type to "text/html"
    - file(css_content, "style.css") sets Content-Type to "text/css"
    - file(data, "file.unknown") sets Content-Type to "application/octet-stream"
    """
    let mime_types = MimeTypes
    let mime_type = mime_types.get_mime_type_from_path(filename)
    let charset = MimeTypes.get_charset(mime_type)

    if charset.size() > 0 then
      _headers.update("Content-Type", mime_type + "; charset=" + charset)
    else
      _headers.update("Content-Type", mime_type)
    end

    _body = content
    _body_set = true
    _headers.update("Content-Length", content.size().string())
    this

  fun ref mime(content: String, mime_type: String): HTTPResponse ref =>
    """
    Set body with explicit MIME type.
    Automatically sets Content-Length header.
    Optionally adds charset for text types.
    """
    let charset = MimeTypes.get_charset(mime_type)

    if charset.size() > 0 then
      _headers.update("Content-Type", mime_type + "; charset=" + charset)
    else
      _headers.update("Content-Type", mime_type)
    end

    _body = content
    _body_set = true
    _headers.update("Content-Length", content.size().string())
    this

  fun ref connection(close: Bool): HTTPResponse ref =>
    """
    Set the Connection header.
    true = "close", false = "keep-alive"
    """
    if close then
      _headers.update("Connection", "close")
    else
      _headers.update("Connection", "keep-alive")
    end
    this

  fun ref chunked(enabled: Bool): HTTPResponse ref =>
    """
    Enable or disable chunked transfer encoding.

    When enabled, the response body will be sent as chunks
    per RFC 9112 Section 7.1. This is useful for streaming
    content where the total size is not known in advance.

    Note: When chunked is enabled, Content-Length header
    is removed and Transfer-Encoding: chunked is added.
    """
    _chunked = enabled
    if enabled then
      try _headers.remove("Content-Length")? end
      _headers.update("Transfer-Encoding", "chunked")
    else
      try _headers.remove("Transfer-Encoding")? end
    end
    this

  fun ref write_chunk(data: String): HTTPResponse ref =>
    """
    Add a chunk of data to a chunked response.

    Must call .chunked(true) before using this method.
    Each chunk will be formatted per RFC 9112:
      hex-size CRLF
      data CRLF

    Example:
      response.chunked(true)
      response.write_chunk("Hello ")
      response.write_chunk("World!")
      // Then render() will produce:
      // 6\r\nHello \r\n
      // 6\r\nWorld!\r\n
      // 0\r\n\r\n
    """
    if not _chunked then
      // Silently ignore if not chunked - could also error
      return this
    end
    _chunks.push(data)
    _body_set = true
    this

  fun ref write_chunk_end(): HTTPResponse ref =>
    """
    Write the final chunk (size 0) to signal end of chunked response.

    This is called automatically by render() if chunked mode is enabled.
    """
    if not _chunked then
      return this
    end
    // Final chunk is added by render()
    this

  fun ref trailer(name: String, value: String): HTTPResponse ref =>
    """
    Add a trailer header to a chunked response.

    Trailers are sent after the final chunk (size 0).
    Per RFC 9112 Section 7.1.2, trailers can include
    metadata like message integrity checks.

    Must call .chunked(true) before using this method.
    """
    if not _chunked then
      return this
    end
    // Store trailers in a special format for rendering
    // For now, add to headers with a special prefix to identify as trailers
    _headers.update("Trailer-" + name, value)
    this

  fun is_chunked(): Bool =>
    """
    Returns true if chunked transfer encoding is enabled.
    """
    _chunked

  fun ref set_date(): HTTPResponse ref =>
    """
    Set the Date header to the current time.
    Format per RFC 9110 Section 5.6.7: HTTP-date
    """
    _headers.update("Date", _http_date())
    this

  fun status_code(): U32 =>
    """
    Get the HTTP status code.
    """
    _status_code

  fun get_status(): U32 =>
    """
    Get the HTTP status code (alias for status_code).
    """
    _status_code

  // Rendering

  fun ref render(): String val =>
    """
    Serialize the response to a string.

    For chunked responses, outputs:
    - Status line and headers
    - Each chunk: hex-size + "\r\n" + data + "\r\n"
    - Last chunk: "0\r\n"
    - Optional trailers + "\r\n"
    """
    // Build status line
    var result = recover String end
    result.append(_version)
    result.push(' ')
    result.append(_status_code.string())
    result.push(' ')
    result.append(_reason_phrase)
    result.append("\r\n")

    // Add headers
    for (name, value) in _headers.pairs() do
      // Skip trailer-prefixed headers (internal marker)
      if not name.substring(0, 8).eq("Trailer-") then
        result.append(name)
        result.append(": ")
        result.append(value)
        result.append("\r\n")
      end
    end

    // End of headers
    result.append("\r\n")

    // Add body (chunked or regular)
    if _chunked then
      _render_chunked(consume result)
    else
      if _body_set then
        result.append(_body)
      end
      consume result
    end

  fun ref _render_chunked(result': String iso): String val =>
    """
    Render chunked body content.

    Format per RFC 9112 Section 7.1:
      chunk = chunk-size [ chunk-ext ] CRLF
              chunk-data CRLF
      last-chunk = 1*("0") [ chunk-ext ] CRLF
    """
    var result = consume result'

    // Render each chunk
    for chunk_data in _chunks.values() do
      match chunk_data
      | let data: String =>
        // Write chunk-size in hex
        result.append(_to_hex(data.size()))
        result.append("\r\n")
        // Write chunk-data
        result.append(data)
        result.append("\r\n")
      end
    end

    // Write last-chunk (size 0)
    result.append("0\r\n")

    // Write trailers if any
    for (name, value) in _headers.pairs() do
      if name.substring(0, 8).eq("Trailer-") then
        // Remove "Trailer-" prefix
        let trailer_name = recover val name.substring(8, name.size().isize()) end
        result.append(trailer_name)
        result.append(": ")
        result.append(value)
        result.append("\r\n")
      end
    end

    // Final CRLF
    result.append("\r\n")

    consume result

  fun _to_hex(n: USize): String =>
    """
    Convert a number to lowercase hexadecimal string.
    """
    if n == 0 then
      return "0"
    end

    let hex_chars = "0123456789abcdef"
    var result = recover String end
    var num = n

    while num > 0 do
      let digit = num % 16
      try
        result.push(hex_chars(digit.usize())?)
      end
      num = num / 16
    end

    // Reverse the string
    let reversed = recover String end
    var i = result.size()
    while i > 0 do
      i = i - 1
      try
        reversed.push(result(i)?)
      end
    end

    consume reversed

  // Static factory methods for common responses

  fun tag ok(body': String val): HTTPResponse =>
    """
    Create a 200 OK response with plain text body.
    """
    HTTPResponse.with_status(200).text(body')

  fun tag ok_html(html': String val): HTTPResponse =>
    """
    Create a 200 OK response with HTML body.
    """
    HTTPResponse.with_status(200).html(html')

  fun tag not_found(): HTTPResponse =>
    """
    Create a 404 Not Found response.
    """
    HTTPResponse.with_status(404)
      .html("<html><body><h1>404 Not Found</h1></body></html>")

  fun tag bad_request(message: String = "Bad Request"): HTTPResponse =>
    """
    Create a 400 Bad Request response.
    """
    HTTPResponse.with_status(400)
      .html("<html><body><h1>400 " + message + "</h1></body></html>")

  fun tag method_not_allowed(): HTTPResponse =>
    """
    Create a 405 Method Not Allowed response.
    """
    HTTPResponse.with_status(405)
      .html("<html><body><h1>405 Method Not Allowed</h1></body></html>")

  fun tag server_error(): HTTPResponse =>
    """
    Create a 500 Internal Server Error response.
    """
    HTTPResponse.with_status(500)
      .html("<html><body><h1>500 Internal Server Error</h1></body></html>")

  // Private helper methods

  fun _default_reason_phrase(code: U32): String =>
    """
    Return the default reason phrase for a status code.
    Per RFC 9110 Section 15.
    """
    match code
    // 1xx Informational
    | 100 => "Continue"
    | 101 => "Switching Protocols"

    // 2xx Success
    | 200 => "OK"
    | 201 => "Created"
    | 202 => "Accepted"
    | 203 => "Non-Authoritative Information"
    | 204 => "No Content"
    | 205 => "Reset Content"
    | 206 => "Partial Content"

    // 3xx Redirection
    | 300 => "Multiple Choices"
    | 301 => "Moved Permanently"
    | 302 => "Found"
    | 303 => "See Other"
    | 304 => "Not Modified"
    | 307 => "Temporary Redirect"
    | 308 => "Permanent Redirect"

    // 4xx Client Error
    | 400 => "Bad Request"
    | 401 => "Unauthorized"
    | 403 => "Forbidden"
    | 404 => "Not Found"
    | 405 => "Method Not Allowed"
    | 406 => "Not Acceptable"
    | 408 => "Request Timeout"
    | 409 => "Conflict"
    | 410 => "Gone"
    | 411 => "Length Required"
    | 412 => "Precondition Failed"
    | 413 => "Payload Too Large"
    | 414 => "URI Too Long"
    | 415 => "Unsupported Media Type"
    | 416 => "Range Not Satisfiable"
    | 417 => "Expectation Failed"
    | 426 => "Upgrade Required"

    // 5xx Server Error
    | 500 => "Internal Server Error"
    | 501 => "Not Implemented"
    | 502 => "Bad Gateway"
    | 503 => "Service Unavailable"
    | 504 => "Gateway Timeout"
    | 505 => "HTTP Version Not Supported"

    else
      "Unknown"
    end

  fun _http_date(): String =>
    """
    Generate HTTP-date string per RFC 9110 Section 5.6.7.
    Format: <day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT
    Example: Sun, 06 Nov 1994 08:49:37 GMT

    Algorithm:
    1. Get Unix timestamp (seconds since Jan 1, 1970)
    2. Calculate days since epoch and time of day
    3. Convert days to year/month/day with leap year handling
    4. Determine day of week from days % 7 (epoch started on Thursday)
    """
    let now = Time.now()
    let seconds = now._1

    // Seconds in a day
    let secs_per_day: I64 = 86400

    // Calculate days since epoch and time components
    let total_days = seconds / secs_per_day
    let remaining_secs = seconds % secs_per_day

    let hours = (remaining_secs / 3600).u32()
    let minutes = ((remaining_secs % 3600) / 60).u32()
    let secs = (remaining_secs % 60).u32()

    // Day names - Unix epoch (Jan 1, 1970) was a Thursday
    // Days % 7: 0=Thu, 1=Fri, 2=Sat, 3=Sun, 4=Mon, 5=Tue, 6=Wed
    let day_names = ["Thu"; "Fri"; "Sat"; "Sun"; "Mon"; "Tue"; "Wed"]
    let day_of_week = ((total_days % 7) + 7) % 7  // Ensure positive
    let day_name = try
      day_names(day_of_week.usize())?
    else
      "???"
    end

    // Calculate year, month, and day from days since epoch
    var days_remaining = total_days
    var year: I64 = 1970

    // Subtract years, accounting for leap years
    while true do
      let is_leap = ((year % 4) == 0) and (((year % 100) != 0) or ((year % 400) == 0))
      let days_in_year: I64 = if is_leap then 366 else 365 end
      if days_remaining < days_in_year then
        break
      end
      days_remaining = days_remaining - days_in_year
      year = year + 1
    end

    // Days in each month (non-leap year)
    let days_in_month: Array[I64] = [
      31; 28; 31; 30; 31; 30; 31; 31; 30; 31; 30; 31
    ]

    // Adjust February for leap year
    let is_leap_year = ((year % 4) == 0) and (((year % 100) != 0) or ((year % 400) == 0))

    // Find month
    var month: USize = 0
    while month < 12 do
      var dim = try
        days_in_month(month)?
      else
        31
      end
      // Adjust February for leap year
      if (month == 1) and is_leap_year then
        dim = 29
      end
      if days_remaining < dim then
        break
      end
      days_remaining = days_remaining - dim
      month = month + 1
    end

    // Day of month (1-based)
    let day_of_month = (days_remaining + 1).u32()

    // Month names
    let month_names = ["Jan"; "Feb"; "Mar"; "Apr"; "May"; "Jun"
                       "Jul"; "Aug"; "Sep"; "Oct"; "Nov"; "Dec"]
    let month_name = try
      month_names(month)?
    else
      "???"
    end

    // Format with zero-padding for day, hour, minute, second
    let day_str = _zero_pad(day_of_month, 2)
    let hour_str = _zero_pad(hours, 2)
    let min_str = _zero_pad(minutes, 2)
    let sec_str = _zero_pad(secs, 2)

    // Format: Day, DD Mon YYYY HH:MM:SS GMT
    day_name + ", " + day_str + " " + month_name + " " + year.string()
      + " " + hour_str + ":" + min_str + ":" + sec_str + " GMT"

  fun _zero_pad(value: U32, digits: USize): String =>
    """
    Convert a number to string with leading zeros to reach specified digits.
    """
    let s = value.string()
    let len = s.size()
    if len >= digits then
      return s
    end

    var result = recover String end
    for i in Range(0, digits - len) do
      result.push('0')
    end
    result.append(consume s)
    consume result
