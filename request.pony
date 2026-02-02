use "collections"
use "format"

class HTTPRequest
  """
  Represents a parsed HTTP/1.1 request.

  Implements parsing per RFC 9112:
  - Request line: method SP request-target SP HTTP-version CRLF
  - Header fields: field-name ":" OWS field-value OWS
  - Chunked transfer encoding per RFC 9112 Section 7.1

  Security limits (to prevent abuse):
  - Max request line length: 8KB
  - Max header size: 8KB per header, 16KB total
  - Max number of headers: 100
  - Max body size: configurable (default 1MB)
  - Max chunk size: 64KB
  - Max total chunks: 1000
  """

  // Security limits
  let _max_request_line_size: USize = 8192   // 8KB
  let _max_header_size: USize = 8192         // 8KB per header
  let _max_total_headers_size: USize = 16384 // 16KB total for all headers
  let _max_header_count: USize = 100
  let _max_body_size: USize                    // Configurable max body size
  let _max_chunk_size: USize = 65536         // 64KB max per chunk
  let _max_chunk_count: USize = 1000         // Max number of chunks
  let _max_chunk_ext_size: USize = 1024      // 1KB max chunk extension size

  var _method: String = ""
  var _path: String = ""
  var _version: String = ""
  var _headers: Map[String, String] = Map[String, String]
  var _query_params: Map[String, Array[String]] = Map[String, Array[String]]
  var _body: String = ""
  var _parse_error: (String | None) = None
  var _total_headers_size: USize = 0
  var _trailers: Map[String, String] = Map[String, String]

  new create(max_body_size: USize = 1048576) =>
    """
    Create an empty HTTP request.

    Parameters:
    - max_body_size: Maximum allowed body size in bytes (default: 1MB = 1048576)
    """
    _max_body_size = max_body_size

  new parse(data: String, max_body_size: USize = 1048576) ? =>
    """
    Parse HTTP request from raw string data.

    Parameters:
    - data: Raw HTTP request data
    - max_body_size: Maximum allowed body size in bytes (default: 1MB = 1048576)

    Raises error if parsing fails.
    """
    _max_body_size = max_body_size
    _parse(data)?

  new from_http2(
    method': String,
    path': String,
    headers': Map[String, String],
    body': Array[U8] box,
    max_body_size: USize = 1048576)
  =>
    """
    Create an HTTP request from HTTP/2 pseudo-headers and data.
    Used by HTTP/2 connection handler.
    """
    _max_body_size = max_body_size
    _method = method'
    // Split path and query string for HTTP/2 as well (":path" can include "?")
    let query_idx = try path'.find("?")? else -1 end
    if query_idx >= 0 then
      _path = path'.substring(0, query_idx)
      let query_string = path'.substring(query_idx + 1, path'.size().isize())
      _parse_query_string(consume query_string)
    else
      _path = path'
    end
    _version = "HTTP/2.0"

    // Copy headers
    for (name, value) in headers'.pairs() do
      // Store uppercase keys for case-insensitive lookup to match HTTP/1.1 parsing.
      _headers.update(name.upper(), value)
    end

    // Convert body from bytes to string
    let body_str = recover String end
    for b in body'.values() do
      body_str.push(b)
    end
    _body = consume body_str

  fun method(): String =>
    """
    Returns the HTTP method (GET, POST, PUT, DELETE, etc.)
    """
    _method

  fun path(): String =>
    """
    Returns the request path/target.
    """
    _path

  fun version(): String =>
    """
    Returns the HTTP version string.
    """
    _version

  fun ref headers(): Map[String, String] =>
    """
    Returns the map of header fields (case-insensitive keys).
    """
    _headers

  fun header(name: String): String =>
    """
    Returns a specific header value, or empty string if not found.
    Header names are case-insensitive.
    """
    try
      _headers(name.upper())?
    else
      ""
    end

  fun body(): String =>
    """
    Returns the request body.
    """
    _body

  fun ref trailers(): Map[String, String] =>
    """
    Returns trailer headers from chunked transfer encoding.
    Only populated when Transfer-Encoding: chunked is used.
    """
    _trailers

  fun trailer(name: String): String =>
    """
    Returns a specific trailer value, or empty string if not found.
    """
    try
      _trailers(name.upper())?
    else
      ""
    end

  fun is_chunked(): Bool =>
    """
    Returns true if the request uses chunked transfer encoding.
    """
    let te = try _headers("TRANSFER-ENCODING")? else "" end
    te.contains("chunked")

  fun query(name: String): String =>
    """
    Returns the first value for a query parameter, or empty string if not found.
    """
    try
      _query_params(name)?(0)?
    else
      ""
    end

  fun query_all(name: String): Array[String] val =>
    """
    Returns all values for a query parameter (for repeated keys).
    Returns empty array if parameter not found.
    """
    try
      let arr = _query_params(name)?
      let result = recover Array[String](arr.size()) end
      for v in arr.values() do
        result.push(v)
      end
      consume result
    else
      recover val Array[String] end
    end

  fun has_query(name: String): Bool =>
    """
    Returns true if the query parameter exists.
    """
    _query_params.contains(name)

  fun query_params(): this->Map[String, Array[String]] =>
    """
    Returns all query parameters as a map of names to arrays of values.
    """
    _query_params

  fun parse_error(): (String | None) =>
    """
    Returns parse error message if parsing failed.
    """
    _parse_error

  fun ref _parse(data: String) ? =>
    """
    Parse the HTTP request.

    Format per RFC 9112:
    request-line = method SP request-target SP HTTP-version CRLF
    *( header-field CRLF )
    CRLF
    [ message-body ]
    """
    // Skip empty lines before request line (RFC 9112 Section 3.1)
    var pos: ISize = 0
    let data_size = data.size().isize()

    while (pos + 1) < data_size do
      if (data(pos.usize())? == '\r') and (data((pos + 1).usize())? == '\n') then
        pos = pos + 2
      else
        break
      end
    end

    // Find end of request line
    let line_end = data.find("\r\n", pos)?
    if line_end < 0 then
      _parse_error = "Missing request line terminator"
      error
    end

    // Check request line length (security limit)
    let request_line_len = (line_end - pos).usize()
    if request_line_len > _max_request_line_size then
      _parse_error = "Request line too large"
      error
    end

    // Parse request line
    let request_line = data.substring(pos, line_end)
    _parse_request_line(consume request_line)?

    // Move past request line
    pos = line_end + 2

    // Parse headers until empty line
    while pos < data_size do
      let header_end = data.find("\r\n", pos)?
      if header_end < 0 then
        _parse_error = "Malformed headers"
        error
      end

      // Check for end of headers (empty line)
      if header_end == pos then
        pos = header_end + 2
        break
      end

      // Check header count limit (security)
      if _headers.size() >= _max_header_count then
        _parse_error = "Too many headers"
        error
      end

      // Check header line length (security limit)
      let header_line_len = (header_end - pos).usize()
      if header_line_len > _max_header_size then
        _parse_error = "Header too large"
        error
      end

      // Check total headers size (security limit)
      _total_headers_size = _total_headers_size + header_line_len
      if _total_headers_size > _max_total_headers_size then
        _parse_error = "Total headers too large"
        error
      end

      // Parse header line
      let header_line = data.substring(pos, header_end)
      _parse_header(consume header_line)?

      pos = header_end + 2
    end

    // Check Content-Length header against max body size before extracting body
    let content_length_str = try
      _headers("CONTENT-LENGTH")?
    else
      ""
    end

    if content_length_str.size() > 0 then
      try
        let content_length = content_length_str.usize()?
        if content_length > _max_body_size then
          _parse_error = "Content-Length exceeds maximum body size"
          error
        end
      else
        _parse_error = "Invalid Content-Length header"
        error
      end
    end

    // Check for Transfer-Encoding: chunked
    let has_chunked_encoding = try
      let te = _headers("TRANSFER-ENCODING")?
      te.contains("chunked")
    else
      false
    end

    if has_chunked_encoding then
      // Parse chunked body
      _parse_chunked_body(data, pos)?
    else
      // Extract body if present (everything after headers)
      if pos < data_size then
        let body_size = (data_size - pos).usize()
        if body_size > _max_body_size then
          _parse_error = "Request body exceeds maximum body size"
          error
        end
        _body = data.substring(pos, data_size)
      end
    end

  fun ref _parse_chunked_body(data: String, start_pos: ISize) ? =>
    """
    Parse chunked transfer-encoded body per RFC 9112 Section 7.1.

    Format:
      chunk = chunk-size [ chunk-ext ] CRLF
              chunk-data CRLF
      last-chunk = 1*("0") [ chunk-ext ] CRLF
      trailer-section = *( field-line CRLF )

    Chunk extensions are parsed and ignored per RFC.
    Trailers are stored separately from headers.
    """
    var pos = start_pos
    let data_size = data.size().isize()
    var total_body_size: USize = 0
    var chunk_count: USize = 0
    let body_parts = Array[String]

    while true do
      // Check chunk count limit
      if chunk_count >= _max_chunk_count then
        _parse_error = "Too many chunks"
        error
      end

      // Find end of chunk-size line (CRLF)
      let line_end = data.find("\r\n", pos)?
      if line_end < 0 then
        _parse_error = "Malformed chunked encoding: missing CRLF after chunk size"
        error
      end

      // Parse chunk-size line
      let chunk_line = data.substring(pos, line_end)

      // Extract chunk-size (hex) and ignore extensions
      let chunk_size = _parse_chunk_size(consume chunk_line)?

      // Move past chunk-size line
      pos = line_end + 2

      // Check for last chunk (size 0)
      if chunk_size == 0 then
        // Parse optional trailers
        _parse_trailers(data, pos)?
        break
      end

      // Validate chunk size
      if chunk_size > _max_chunk_size then
        _parse_error = "Chunk size exceeds maximum"
        error
      end

      // Check total body size
      total_body_size = total_body_size + chunk_size
      if total_body_size > _max_body_size then
        _parse_error = "Chunked body exceeds maximum body size"
        error
      end

      // Read chunk data
      let chunk_end = pos + chunk_size.isize()
      if chunk_end > data_size then
        _parse_error = "Incomplete chunk data"
        error
      end

      let chunk_data = data.substring(pos, chunk_end)
      body_parts.push(consume chunk_data)

      // Move past chunk data
      pos = chunk_end

      // Verify CRLF after chunk data
      if (pos + 2) > data_size then
        _parse_error = "Missing CRLF after chunk data"
        error
      end

      try
        if (data(pos.usize())? != '\r') or (data((pos + 1).usize())? != '\n') then
          _parse_error = "Missing CRLF after chunk data"
          error
        end
      else
        _parse_error = "Missing CRLF after chunk data"
        error
      end

      pos = pos + 2
      chunk_count = chunk_count + 1
    end

    // Combine all chunk data into body
    let combined_body = recover String(total_body_size) end
    for part in body_parts.values() do
      combined_body.append(part)
    end
    _body = consume combined_body

  fun ref _parse_chunk_size(line: String): USize ? =>
    """
    Parse chunk-size from chunk-size line, ignoring chunk extensions.

    Per RFC 9112 Section 7.1:
      chunk-size = 1*HEXDIG
      chunk-ext = *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] )

    Returns the chunk size in bytes, or error if invalid.
    """
    // Find semicolon (start of extensions) or end of line
    var end_idx = line.size().isize()
    try
      let semi_idx = line.find(";")?
      if semi_idx >= 0 then
        end_idx = semi_idx
      end
    end

    // Extract hex size
    let hex_str = line.substring(0, end_idx)
    let trimmed = _trim_whitespace(consume hex_str)

    if trimmed.size() == 0 then
      _parse_error = "Missing chunk size"
      error
    end

    // Parse hex number
    _parse_hex(consume trimmed)

  fun ref _parse_hex(hex_str: String): USize =>
    """
    Parse a hexadecimal string to USize.
    Returns error if invalid hex digit found.
    """
    var result: USize = 0

    for i in Range(0, hex_str.size()) do
      try
        let c = hex_str(i)?
        let digit: USize =
          if (c >= '0') and (c <= '9') then
            (c - '0').usize()
          elseif (c >= 'A') and (c <= 'F') then
            ((c - 'A') + 10).usize()
          elseif (c >= 'a') and (c <= 'f') then
            ((c - 'a') + 10).usize()
          else
            _parse_error = "Invalid hex digit in chunk size"
            error
          end

        // Check for overflow
        if result > ((_max_body_size - digit) / 16) then
          _parse_error = "Chunk size overflow"
          error
        end

        result = (result * 16) + digit
      end
    end

    result

  fun ref _parse_trailers(data: String, start_pos: ISize) ? =>
    """
    Parse trailer headers after the last chunk.

    Per RFC 9112 Section 7.1.2:
      trailer-section = *( field-line CRLF )
      CRLF

    Trailers are stored separately from headers.
    """
    var pos = start_pos
    let data_size = data.size().isize()

    while true do
      // Find end of line
      let line_end = data.find("\r\n", pos)?
      if line_end < 0 then
        _parse_error = "Malformed trailers"
        error
      end

      // Check for end of trailers (empty line)
      if line_end == pos then
        // Final CRLF
        break
      end

      // Parse trailer field
      let line = data.substring(pos, line_end)
      _parse_trailer_line(consume line)?

      pos = line_end + 2
    end

  fun ref _parse_trailer_line(line: String) ? =>
    """
    Parse a single trailer field line.
    Similar to header parsing but stored in trailers map.
    """
    // Find the colon separator
    let colon_idx = line.find(":")?

    if colon_idx < 0 then
      _parse_error = "Invalid trailer: missing colon"
      error
    end

    // Extract field name (before colon)
    let name = line.substring(0, colon_idx)
    let name_trimmed = _trim_whitespace(consume name)

    // Extract field value (after colon)
    let value = line.substring(colon_idx + 1, line.size().isize())
    let value_trimmed = _trim_whitespace(consume value)

    // Store trailer with uppercase name for case-insensitive lookup
    _trailers.update(name_trimmed.upper(), consume value_trimmed)

  fun ref _parse_request_line(line: String) ? =>
    """
    Parse request line: method SP request-target SP HTTP-version

    Per RFC 9112 Section 3:
    - method = token
    - request-target = origin-form | absolute-form | authority-form | asterisk-form
    - HTTP-version = "HTTP" "/" DIGIT "." DIGIT
    """
    // Split by space
    let parts = line.split(" ")

    if parts.size() < 2 then
      _parse_error = "Invalid request line format"
      error
    end

    _method = try parts(0)? else "" end
    _method = _method.upper()

    // Validate method (RFC 9110 Section 9.1)
    match _method
    | "GET" | "HEAD" | "POST" | "PUT" | "DELETE" |
      "CONNECT" | "OPTIONS" | "TRACE" => None
    else
      _parse_error = "Unknown method: " + _method
      error
    end

    let request_target = try parts(1)? else "/" end

    // Split path and query string
    let query_idx = try request_target.find("?")? else -1 end
    if query_idx >= 0 then
      _path = request_target.substring(0, query_idx)
      let query_string = request_target.substring(query_idx + 1, request_target.size().isize())
      _parse_query_string(consume query_string)
    else
      _path = consume request_target
    end

    // HTTP version (optional in some cases, but required per spec)
    if parts.size() >= 3 then
      _version = try parts(2)? else "HTTP/1.1" end
    else
      _version = "HTTP/1.1"
    end

    // Validate HTTP version format (security check)
    if not _is_valid_http_version(_version) then
      _parse_error = "Invalid HTTP version"
      error
    end

  fun ref _parse_header(line: String) ? =>
    """
    Parse a header field.

    Per RFC 9112 Section 5.1:
    header-field = field-name ":" OWS field-value OWS

    Servers MUST reject whitespace between field-name and colon (400 Bad Request).
    """
    // Find the colon separator
    let colon_idx = line.find(":")?

    if colon_idx < 0 then
      _parse_error = "Invalid header: missing colon"
      error
    end

    // Extract field name (before colon)
    let name = line.substring(0, colon_idx)
    let name_trimmed = _trim_whitespace(consume name)

    // Per RFC 9112: reject whitespace between field-name and colon
    if name_trimmed.size() < colon_idx.usize() then
      _parse_error = "Whitespace between header name and colon"
      error
    end

    // Extract field value (after colon)
    let value = line.substring(colon_idx + 1, line.size().isize())
    let value_trimmed = _trim_whitespace(consume value)

    // Store header with uppercase name for case-insensitive lookup
    _headers.update(name_trimmed.upper(), consume value_trimmed)

  fun _trim_whitespace(s: String): String =>
    """
    Trim leading and trailing whitespace (SP and HTAB).
    OWS = *( SP / HTAB )
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

  fun url_decode(url_path: String): String =>
    """
    Decode URL-encoded path (percent-encoding per RFC 3986).
    """
    let result = recover String end
    var i: USize = 0

    while i < url_path.size() do
      try
        if (url_path(i)? == '%') and ((i + 2) < url_path.size()) then
          // Percent-encoded byte
          let hi = _hex_digit(url_path(i + 1)?)
          let lo = _hex_digit(url_path(i + 2)?)
          if (hi >= 0) and (lo >= 0) then
            result.push(U8.from[U32]((hi.u32() << 4) + lo.u32()))
            i = i + 3
            continue
          end
        elseif url_path(i)? == '+' then
          // Plus sign decodes to space (for query strings)
          result.push(' ')
          i = i + 1
          continue
        end
        result.push(url_path(i)?)
      end
      i = i + 1
    end

    consume result

  fun _hex_digit(c: U8): I32 =>
    """
    Convert hex digit character to numeric value.
    Returns -1 if not a valid hex digit.
    """
    if (c >= '0') and (c <= '9') then
      (c - '0').i32()
    elseif (c >= 'A') and (c <= 'F') then
      ((c - 'A') + 10).i32()
    elseif (c >= 'a') and (c <= 'f') then
      ((c - 'a') + 10).i32()
    else
      -1
    end

  fun _is_valid_http_version(ver: String): Bool =>
    """
    Validate HTTP version format.
    Must be "HTTP/X.Y" where X and Y are digits.
    """
    // Check basic format: HTTP/DIGIT.DIGIT
    if ver.size() < 8 then
      return false
    end

    // Check starts with "HTTP/"
    if ver.compare_sub("HTTP/", 5, 0) != Equal then
      return false
    end

    // Check format: digit.digit at the end
    try
      let major = ver(5)?
      let dot = ver(6)?
      let minor = ver(7)?

      if (major < '0') or (major > '9') then
        return false
      end
      if dot != '.' then
        return false
      end
      if (minor < '0') or (minor > '9') then
        return false
      end
    else
      return false
    end

    true

  fun ref _parse_query_string(query_string: String) =>
    """
    Parse query string into key-value pairs.

    Handles:
    - foo=bar&baz=qux (normal key=value pairs)
    - foo&bar (keys without values)
    - foo= (empty value)
    - foo=1&foo=2 (repeated keys - collect all values)
    - URL decoding (%XX -> char, + -> space)

    Malformed query strings are handled gracefully (skip invalid parts).
    """
    if query_string.size() == 0 then
      return
    end

    // Split by '&' to get individual parameters
    let params = query_string.split("&")

    for param in (consume ref params).values() do
      if param.size() == 0 then
        continue  // Skip empty parameters
      end

      // Find '=' to separate key and value
      let eq_idx = try param.find("=")? else -1 end

      var key: String
      var value: String

      if eq_idx >= 0 then
        // Has '=' separator
        key = param.substring(0, eq_idx)
        value = param.substring(eq_idx + 1, param.size().isize())
      else
        // No value (e.g., "foo" without "=bar")
        key = consume param
        value = ""
      end

      // URL decode both key and value
      let decoded_key = url_decode(key)
      let decoded_value = url_decode(value)

      // Store in map (handle repeated keys by appending to array)
      try
        if _query_params.contains(decoded_key) then
          _query_params(decoded_key)?.push(decoded_value)
        else
          let arr = Array[String]
          arr.push(decoded_value)
          _query_params.update(decoded_key, consume arr)
        end
      end
    end
