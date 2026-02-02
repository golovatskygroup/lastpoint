use "time"
use "collections"

primitive LogLevelDebug
primitive LogLevelInfo
primitive LogLevelWarn
primitive LogLevelError

type LogLevel is
  ( LogLevelDebug
  | LogLevelInfo
  | LogLevelWarn
  | LogLevelError
  )

primitive LogFormatText
primitive LogFormatJSON

type LogFormat is
  ( LogFormatText
  | LogFormatJSON
  )

class val LogFields
  """
  Holds optional contextual data for log entries.
  All fields are optional and only included in output if set.
  """
  let connection_id: (USize | None)
  let request_num: (USize | None)
  let method: (String | None)
  let path: (String | None)
  let status_code: (U32 | None)
  let duration_micros: (U64 | None)
  let stream_id: (U32 | None)

  new val create(
    connection_id': (USize | None) = None,
    request_num': (USize | None) = None,
    method': (String | None) = None,
    path': (String | None) = None,
    status_code': (U32 | None) = None,
    duration_micros': (U64 | None) = None,
    stream_id': (U32 | None) = None)
  =>
    """
    Create a new LogFields instance with optional fields.
    """
    connection_id = connection_id'
    request_num = request_num'
    method = method'
    path = path'
    status_code = status_code'
    duration_micros = duration_micros'
    stream_id = stream_id'

  fun val with_connection_id(id: USize): LogFields val =>
    """Return a new LogFields with connection_id set."""
    LogFields(id, request_num, method, path, status_code, duration_micros, stream_id)

  fun val with_request_num(num: USize): LogFields val =>
    """Return a new LogFields with request_num set."""
    LogFields(connection_id, num, method, path, status_code, duration_micros, stream_id)

  fun val with_method(m: String): LogFields val =>
    """Return a new LogFields with method set."""
    LogFields(connection_id, request_num, m, path, status_code, duration_micros, stream_id)

  fun val with_path(p: String): LogFields val =>
    """Return a new LogFields with path set."""
    LogFields(connection_id, request_num, method, p, status_code, duration_micros, stream_id)

  fun val with_status_code(code: U32): LogFields val =>
    """Return a new LogFields with status_code set."""
    LogFields(connection_id, request_num, method, path, code, duration_micros, stream_id)

  fun val with_duration_micros(micros: U64): LogFields val =>
    """Return a new LogFields with duration_micros set."""
    LogFields(connection_id, request_num, method, path, status_code, micros, stream_id)

  fun val with_stream_id(sid: U32): LogFields val =>
    """Return a new LogFields with stream_id set (for HTTP/2)."""
    LogFields(connection_id, request_num, method, path, status_code, duration_micros, sid)

actor Logger
  """
  Structured logging actor for the HTTP server.

  Supports multiple log levels (DEBUG, INFO, WARN, ERROR) and
  output formats (TEXT, JSON). Log entries include timestamps
  in ISO 8601 format and optional contextual fields.

  TEXT format: 2025-01-30T12:30:45Z [INFO] message field1=value1
  JSON format: {"timestamp":"2025-01-30T12:30:45Z","level":"INFO","message":"...",...}
  """

  let _env: Env
  let _level: LogLevel
  let _format: LogFormat

  new create(
    env: Env,
    level: LogLevel = LogLevelInfo,
    format: LogFormat = LogFormatText)
  =>
    """
    Create a new Logger.

    Parameters:
    - env: The environment for output
    - level: Minimum log level to output (default: INFO)
    - format: Output format TEXT or JSON (default: TEXT)
    """
    _env = env
    _level = level
    _format = format

  be debug(msg: String, fields: LogFields val = recover val LogFields end) =>
    """
    Log a DEBUG level message.
    """
    _log(LogLevelDebug, msg, fields)

  be info(msg: String, fields: LogFields val = recover val LogFields end) =>
    """
    Log an INFO level message.
    """
    _log(LogLevelInfo, msg, fields)

  be warn(msg: String, fields: LogFields val = recover val LogFields end) =>
    """
    Log a WARN level message.
    """
    _log(LogLevelWarn, msg, fields)

  be log_error(msg: String, fields: LogFields val = recover val LogFields end) =>
    """
    Log an ERROR level message.
    Note: Named log_error instead of error because error is a reserved keyword in Pony.
    """
    _log(LogLevelError, msg, fields)

  fun ref _log(level: LogLevel, msg: String, fields: LogFields val) =>
    """
    Internal method to process and output a log entry.
    Filters based on configured log level.
    """
    // Check log level filtering
    if not _should_log(level) then
      return
    end

    let timestamp = _iso_timestamp()
    let level_str = _level_string(level)

    match _format
    | LogFormatText =>
      _output_text(timestamp, level_str, msg, fields)
    | LogFormatJSON =>
      _output_json(timestamp, level_str, msg, fields)
    end

  fun _should_log(level: LogLevel): Bool =>
    """
    Check if the given log level should be logged based on configuration.
    Returns true if level is >= configured level.
    """
    match _level
    | LogLevelDebug => true
    | LogLevelInfo =>
      match level
      | LogLevelDebug => false
      else true
      end
    | LogLevelWarn =>
      match level
      | LogLevelDebug | LogLevelInfo => false
      else true
      end
    | LogLevelError =>
      match level
      | LogLevelError => true
      else false
      end
    end

  fun _level_string(level: LogLevel): String =>
    """
    Convert log level to string representation.
    """
    match level
    | LogLevelDebug => "DEBUG"
    | LogLevelInfo => "INFO"
    | LogLevelWarn => "WARN"
    | LogLevelError => "ERROR"
    end

  fun _iso_timestamp(): String =>
    """
    Generate ISO 8601 timestamp in UTC format: YYYY-MM-DDTHH:MM:SSZ
    """
    let now = Time.now()
    let seconds = now._1
    let nanoseconds = now._2

    // Seconds in a day
    let secs_per_day: I64 = 86400

    // Calculate days since epoch and time components
    let total_days = seconds / secs_per_day
    let remaining_secs = seconds % secs_per_day

    let hours = (remaining_secs / 3600).u32()
    let minutes = ((remaining_secs % 3600) / 60).u32()
    let secs = (remaining_secs % 60).u32()

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

    // Format: YYYY-MM-DDTHH:MM:SSZ
    _zero_pad(year.u32(), 4) + "-" +
    _zero_pad(month.u32() + 1, 2) + "-" +
    _zero_pad(day_of_month, 2) + "T" +
    _zero_pad(hours, 2) + ":" +
    _zero_pad(minutes, 2) + ":" +
    _zero_pad(secs, 2) + "Z"

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

  fun _output_text(
    timestamp: String,
    level: String,
    msg: String,
    fields: LogFields val)
  =>
    """
    Output log entry in TEXT format:
    2025-01-30T12:30:45Z [INFO] message field1=value1 field2=value2
    """
    var output = recover String end
    output.append(timestamp)
    output.append(" [")
    output.append(level)
    output.append("] ")
    output.append(msg)

    // Add optional fields if present
    match fields.connection_id
    | let id: USize =>
      output.append(" connection_id=")
      output.append(id.string())
    end

    match fields.request_num
    | let num: USize =>
      output.append(" request_num=")
      output.append(num.string())
    end

    match fields.method
    | let m: String =>
      output.append(" method=")
      output.append(m)
    end

    match fields.path
    | let p: String =>
      output.append(" path=")
      output.append(p)
    end

    match fields.status_code
    | let code: U32 =>
      output.append(" status_code=")
      output.append(code.string())
    end

    match fields.duration_micros
    | let micros: U64 =>
      output.append(" duration_micros=")
      output.append(micros.string())
    end

    match fields.stream_id
    | let sid: U32 =>
      output.append(" stream_id=")
      output.append(sid.string())
    end

    _env.out.print(consume output)

  fun _escape_json_string(s: String): String =>
    """
    Escape special characters in a string for JSON output.
    Handles quotes, backslashes, and control characters.
    """
    var result = recover String end
    for c in s.values() do
      match c
      | '"' => result.append("\\\"")
      | '\\' => result.append("\\\\")
      | '\b' => result.append("\\b")
      | '\f' => result.append("\\f")
      | '\n' => result.append("\\n")
      | '\r' => result.append("\\r")
      | '\t' => result.append("\\t")
      else
        // Check for other control characters (0x00-0x1F)
        if (c < 0x20) then
          result.append("\\u00")
          let hex = _byte_to_hex(c)
          result.append(hex)
        else
          result.push(c)
        end
      end
    end
    consume result

  fun _byte_to_hex(b: U8): String =>
    """
    Convert a byte to its 2-digit hexadecimal representation.
    """
    let hex_chars = "0123456789ABCDEF"
    let hi = (b >> 4).usize()
    let lo = (b and 0x0F).usize()
    var result = recover String end
    try
      result.push(hex_chars(hi)?)
      result.push(hex_chars(lo)?)
    end
    consume result

  fun _output_json(
    timestamp: String,
    level: String,
    msg: String,
    fields: LogFields val)
  =>
    """
    Output log entry in JSON format:
    {"timestamp":"2025-01-30T12:30:45Z","level":"INFO","message":"...",...}
    """
    var output = recover String end
    output.append("{\"timestamp\":\"")
    output.append(timestamp)
    output.append("\",\"level\":\"")
    output.append(level)
    output.append("\",\"message\":\"")
    output.append(_escape_json_string(msg))
    output.append("\"")

    // Add optional fields if present
    match fields.connection_id
    | let id: USize =>
      output.append(",\"connection_id\":")
      output.append(id.string())
    end

    match fields.request_num
    | let num: USize =>
      output.append(",\"request_num\":")
      output.append(num.string())
    end

    match fields.method
    | let m: String =>
      output.append(",\"method\":\"")
      output.append(_escape_json_string(m))
      output.append("\"")
    end

    match fields.path
    | let p: String =>
      output.append(",\"path\":\"")
      output.append(_escape_json_string(p))
      output.append("\"")
    end

    match fields.status_code
    | let code: U32 =>
      output.append(",\"status_code\":")
      output.append(code.string())
    end

    match fields.duration_micros
    | let micros: U64 =>
      output.append(",\"duration_micros\":")
      output.append(micros.string())
    end

    match fields.stream_id
    | let sid: U32 =>
      output.append(",\"stream_id\":")
      output.append(sid.string())
    end

    output.append("}")
    _env.out.print(consume output)
