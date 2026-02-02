use "files"
use "collections"

primitive _EnvUtil
  """
  Utility for accessing environment variables from env.vars array.
  """
  fun get_env_var(env: Env, key: String): (String | None) =>
    """
    Get an environment variable value by key.
    Returns the value if found, None otherwise.
    """
    let prefix = recover val key + "=" end
    for entry in env.vars.values() do
      try
        if entry.at(prefix, 0) then
          // Found the entry, extract the value after "KEY="
          return entry.substring(prefix.isize()?)
        end
      end
    end
    None

class val Config
  """
  Configuration class for the HTTP server.

  Supports loading from JSON configuration files, environment variables,
  and command line arguments with the following precedence:
  1. Environment variables (highest priority)
  2. Command line arguments
  3. Configuration file
  4. Default values (lowest priority)

  Configuration options:
    server.host (string, default: "0.0.0.0")
    server.port (string, default: "8080")
    server.tls.enabled (bool, default: false)
    server.tls.cert_file (string, default: "")
    server.tls.key_file (string, default: "")
    limits.max_body_size (usize, default: 1048576 = 1MB)
    limits.max_headers_size (usize, default: 16384)
    limits.timeout_seconds (usize, default: 30)
    logging.level (string, default: "info")
    logging.format (string, default: "text")
  """

  // Server settings
  let host: String val
  let port: String val

  // TLS settings
  let tls_enabled: Bool val
  let tls_cert_file: String val
  let tls_key_file: String val

  // Limits settings
  let max_body_size: USize val
  let max_headers_size: USize val
  let timeout_seconds: USize val

  // Logging settings
  let log_level: String val
  let log_format: String val

  new val create(
    host': String val = "0.0.0.0",
    port': String val = "8080",
    tls_enabled': Bool val = false,
    tls_cert_file': String val = "",
    tls_key_file': String val = "",
    max_body_size': USize val = 1048576,
    max_headers_size': USize val = 16384,
    timeout_seconds': USize val = 30,
    log_level': String val = "info",
    log_format': String val = "text")
  =>
    """
    Create a new Config with the specified values.
    """
    host = host'
    port = port'
    tls_enabled = tls_enabled'
    tls_cert_file = tls_cert_file'
    tls_key_file = tls_key_file'
    max_body_size = max_body_size'
    max_headers_size = max_headers_size'
    timeout_seconds = timeout_seconds'
    log_level = log_level'
    log_format = log_format'

  fun val with_host(new_host: String val): Config val =>
    """Return a new Config with the host updated."""
    Config(
      new_host, port, tls_enabled, tls_cert_file, tls_key_file,
      max_body_size, max_headers_size, timeout_seconds, log_level, log_format
    )

  fun val with_port(new_port: String val): Config val =>
    """Return a new Config with the port updated."""
    Config(
      host, new_port, tls_enabled, tls_cert_file, tls_key_file,
      max_body_size, max_headers_size, timeout_seconds, log_level, log_format
    )

  fun val with_tls_enabled(enabled: Bool val): Config val =>
    """Return a new Config with TLS enabled updated."""
    Config(
      host, port, enabled, tls_cert_file, tls_key_file,
      max_body_size, max_headers_size, timeout_seconds, log_level, log_format
    )

  fun val with_tls_cert_file(cert_file: String val): Config val =>
    """Return a new Config with TLS cert file updated."""
    Config(
      host, port, tls_enabled, cert_file, tls_key_file,
      max_body_size, max_headers_size, timeout_seconds, log_level, log_format
    )

  fun val with_tls_key_file(key_file: String val): Config val =>
    """Return a new Config with TLS key file updated."""
    Config(
      host, port, tls_enabled, tls_cert_file, key_file,
      max_body_size, max_headers_size, timeout_seconds, log_level, log_format
    )

  fun val with_max_body_size(size: USize val): Config val =>
    """Return a new Config with max body size updated."""
    Config(
      host, port, tls_enabled, tls_cert_file, tls_key_file,
      size, max_headers_size, timeout_seconds, log_level, log_format
    )

  fun val with_max_headers_size(size: USize val): Config val =>
    """Return a new Config with max headers size updated."""
    Config(
      host, port, tls_enabled, tls_cert_file, tls_key_file,
      max_body_size, size, timeout_seconds, log_level, log_format
    )

  fun val with_timeout_seconds(seconds: USize val): Config val =>
    """Return a new Config with timeout seconds updated."""
    Config(
      host, port, tls_enabled, tls_cert_file, tls_key_file,
      max_body_size, max_headers_size, seconds, log_level, log_format
    )

  fun val with_log_level(level: String val): Config val =>
    """Return a new Config with log level updated."""
    Config(
      host, port, tls_enabled, tls_cert_file, tls_key_file,
      max_body_size, max_headers_size, timeout_seconds, level, log_format
    )

  fun val with_log_format(format: String val): Config val =>
    """Return a new Config with log format updated."""
    Config(
      host, port, tls_enabled, tls_cert_file, tls_key_file,
      max_body_size, max_headers_size, timeout_seconds, log_level, format
    )

primitive ConfigLoader
  """
  Loads configuration from various sources: JSON files, environment variables,
  and command line arguments.
  """

  fun load(env: Env, args: Array[String] val): (Config val | String) =>
    """
    Load configuration from all sources with the following precedence:
    1. Start with default values
    2. Override with config file if specified
    3. Override with command line arguments
    4. Override with environment variables (highest priority)

    Returns either a valid Config or an error message.
    """
    // Start with defaults
    var config: Config val = Config

    // Parse command line to find --config option
    var config_file_path: (String | None) = None
    var skip_next = false

    for i in Range[USize](1, args.size()) do
      if skip_next then
        skip_next = false
        continue
      end

      try
        let arg = args(i)?
        if arg == "--config" then
          if (i + 1) < args.size() then
            try
              config_file_path = args(i + 1)?
              skip_next = true
            end
          end
        end
      end
    end

    // Load from config file if specified
    match config_file_path
    | let path: String =>
      match _load_from_file(env, path)
      | let file_config: Config val =>
        config = file_config
      | let err: String =>
        // If file was explicitly specified but couldn't be loaded, return error
        return err
      end
    end

    // Apply command line arguments
    config = _apply_args(config, args)

    // Apply environment variables (highest priority)
    config = _apply_env_vars(env, config)

    // Validate the configuration
    match _validate(config)
    | let err: String =>
      return err
    end

    config

  fun _load_from_file(env: Env, path: String): (Config val | String) =>
    """
    Load configuration from a JSON file.
    Returns Config on success, error message on failure.
    """
    // Try to open the file
    let file_path = FilePath(FileAuth(env.root), path)
    if not file_path.exists() then
      return "Configuration file not found: " + path
    end

    let file = File.open(file_path)

    // Read file contents
    let content' = file.read_string(file.size())
    file.dispose()

    // Parse JSON using our simple parser
    let content = consume content'
    let parser = _JsonParser(consume content)
    match parser.parse()
    | let obj: Map[String, _JsonValue] =>
      _parse_config_from_json(obj)
    | let err: String =>
      "Invalid JSON in configuration file: " + err
    end

  fun _parse_config_from_json(root: Map[String, _JsonValue] ref): (Config val | String) =>
    """
    Parse configuration values from JSON object.
    """
    var config: Config val = Config

    // Parse server section
    try
      let server_val = root("server")?
      match server_val.get_object()
      | let server: Map[String, _JsonValue] ref =>
        // server.host
        try
          match server("host")?.get_string()
          | let s: String => config = config.with_host(s)
          end
        end

        // server.port
        try
          match server("port")?.get_string()
          | let s: String => config = config.with_port(s)
          end
        end

        // server.tls
        try
          match server("tls")?.get_object()
          | let tls: Map[String, _JsonValue] ref =>
            // server.tls.enabled
            try
              match tls("enabled")?.get_bool()
              | let b: Bool => config = config.with_tls_enabled(b)
              end
            end

            // server.tls.cert_file
            try
              match tls("cert_file")?.get_string()
              | let s: String => config = config.with_tls_cert_file(s)
              end
            end

            // server.tls.key_file
            try
              match tls("key_file")?.get_string()
              | let s: String => config = config.with_tls_key_file(s)
              end
            end
          end
        end
      end
    end

    // Parse limits section
    try
      match root("limits")?.get_object()
      | let limits: Map[String, _JsonValue] ref =>
        // limits.max_body_size
        try
          match limits("max_body_size")?.get_int()
          | let n: I64 => config = config.with_max_body_size(n.usize())
          end
        end

        // limits.max_headers_size
        try
          match limits("max_headers_size")?.get_int()
          | let n: I64 => config = config.with_max_headers_size(n.usize())
          end
        end

        // limits.timeout_seconds
        try
          match limits("timeout_seconds")?.get_int()
          | let n: I64 => config = config.with_timeout_seconds(n.usize())
          end
        end
      end
    end

    // Parse logging section
    try
      match root("logging")?.get_object()
      | let logging: Map[String, _JsonValue] ref =>
        // logging.level
        try
          match logging("level")?.get_string()
          | let s: String => config = config.with_log_level(s)
          end
        end

        // logging.format
        try
          match logging("format")?.get_string()
          | let s: String => config = config.with_log_format(s)
          end
        end
      end
    end

    config

  fun _apply_args(config: Config val, args: Array[String] val): Config val =>
    """
    Apply command line arguments to override config values.
    """
    var result = config
    var skip_next = false

    for i in Range[USize](1, args.size()) do
      if skip_next then
        skip_next = false
        continue
      end

      try
        let arg = args(i)?

        match arg
        | "--host" =>
          if (i + 1) < args.size() then
            try
              result = result.with_host(args(i + 1)?)
              skip_next = true
            end
          end
        | "--port" =>
          if (i + 1) < args.size() then
            try
              result = result.with_port(args(i + 1)?)
              skip_next = true
            end
          end
        | "--tls-enabled" =>
          result = result.with_tls_enabled(true)
        | "--tls-cert-file" =>
          if (i + 1) < args.size() then
            try
              result = result.with_tls_cert_file(args(i + 1)?)
              skip_next = true
            end
          end
        | "--tls-key-file" =>
          if (i + 1) < args.size() then
            try
              result = result.with_tls_key_file(args(i + 1)?)
              skip_next = true
            end
          end
        | "--max-body-size" =>
          if (i + 1) < args.size() then
            try
              let size = args(i + 1)?.usize()?
              result = result.with_max_body_size(size)
              skip_next = true
            end
          end
        | "--max-headers-size" =>
          if (i + 1) < args.size() then
            try
              let size = args(i + 1)?.usize()?
              result = result.with_max_headers_size(size)
              skip_next = true
            end
          end
        | "--timeout" =>
          if (i + 1) < args.size() then
            try
              let timeout = args(i + 1)?.usize()?
              result = result.with_timeout_seconds(timeout)
              skip_next = true
            end
          end
        | "--log-level" =>
          if (i + 1) < args.size() then
            try
              result = result.with_log_level(args(i + 1)?)
              skip_next = true
            end
          end
        | "--log-format" =>
          if (i + 1) < args.size() then
            try
              result = result.with_log_format(args(i + 1)?)
              skip_next = true
            end
          end
        | "--read-timeout" =>
          // Legacy option mapped to timeout_seconds
          if (i + 1) < args.size() then
            try
              let timeout = args(i + 1)?.usize()?
              result = result.with_timeout_seconds(timeout)
              skip_next = true
            end
          end
        end
      end
    end

    result

  fun _apply_env_vars(env: Env, config: Config val): Config val =>
    """
    Apply environment variables to override config values.
    Environment variables have the highest priority.
    """
    var result = config

    // HTTP_SERVER_HOST
    match _EnvUtil.get_env_var(env, "HTTP_SERVER_HOST")
    | let host: String =>
      result = result.with_host(host)
    end

    // HTTP_SERVER_PORT
    match _EnvUtil.get_env_var(env, "HTTP_SERVER_PORT")
    | let port: String =>
      result = result.with_port(port)
    end

    // HTTP_SERVER_TLS_ENABLED
    match _EnvUtil.get_env_var(env, "HTTP_SERVER_TLS_ENABLED")
    | let tls_enabled_str: String =>
      let enabled = (tls_enabled_str == "true") or (tls_enabled_str == "1")
      result = result.with_tls_enabled(enabled)
    end

    // HTTP_SERVER_TLS_CERT_FILE
    match _EnvUtil.get_env_var(env, "HTTP_SERVER_TLS_CERT_FILE")
    | let cert_file: String =>
      result = result.with_tls_cert_file(cert_file)
    end

    // HTTP_SERVER_TLS_KEY_FILE
    match _EnvUtil.get_env_var(env, "HTTP_SERVER_TLS_KEY_FILE")
    | let key_file: String =>
      result = result.with_tls_key_file(key_file)
    end

    // HTTP_SERVER_MAX_BODY_SIZE
    match _EnvUtil.get_env_var(env, "HTTP_SERVER_MAX_BODY_SIZE")
    | let max_body_str: String =>
      try
        let max_body = max_body_str.usize()?
        result = result.with_max_body_size(max_body)
      end
    end

    // HTTP_SERVER_MAX_HEADERS_SIZE
    match _EnvUtil.get_env_var(env, "HTTP_SERVER_MAX_HEADERS_SIZE")
    | let max_headers_str: String =>
      try
        let max_headers = max_headers_str.usize()?
        result = result.with_max_headers_size(max_headers)
      end
    end

    // HTTP_SERVER_TIMEOUT_SECONDS
    match _EnvUtil.get_env_var(env, "HTTP_SERVER_TIMEOUT_SECONDS")
    | let timeout_str: String =>
      try
        let timeout = timeout_str.usize()?
        result = result.with_timeout_seconds(timeout)
      end
    end

    // HTTP_SERVER_LOG_LEVEL
    match _EnvUtil.get_env_var(env, "HTTP_SERVER_LOG_LEVEL")
    | let log_level: String =>
      result = result.with_log_level(log_level)
    end

    // HTTP_SERVER_LOG_FORMAT
    match _EnvUtil.get_env_var(env, "HTTP_SERVER_LOG_FORMAT")
    | let log_format: String =>
      result = result.with_log_format(log_format)
    end

    result

  fun _validate(config: Config val): (None | String) =>
    """
    Validate configuration values.
    Returns None if valid, error message if invalid.
    """
    // Validate host is not empty
    if config.host.size() == 0 then
      return "Invalid configuration: host cannot be empty"
    end

    // Validate port is not empty
    if config.port.size() == 0 then
      return "Invalid configuration: port cannot be empty"
    end

    // Validate port is a valid number
    try
      let port_num = config.port.u16()?
      if (port_num == 0) or (port_num > 65535) then
        return "Invalid configuration: port must be between 1 and 65535"
      end
    else
      return "Invalid configuration: port must be a valid number"
    end

    // Validate max_body_size is reasonable (at least 1KB)
    if config.max_body_size < 1024 then
      return "Invalid configuration: max_body_size must be at least 1024 bytes"
    end

    // Validate max_headers_size is reasonable (at least 1KB)
    if config.max_headers_size < 1024 then
      return "Invalid configuration: max_headers_size must be at least 1024 bytes"
    end

    // Validate timeout_seconds is reasonable (at least 1 second)
    if config.timeout_seconds < 1 then
      return "Invalid configuration: timeout_seconds must be at least 1"
    end

    // Validate log_level
    let valid_levels = ["debug"; "info"; "warn"; "error"]
    var valid_level = false
    for level in valid_levels.values() do
      if level == config.log_level then
        valid_level = true
        break
      end
    end
    if not valid_level then
      return "Invalid configuration: log_level must be one of: debug, info, warn, error"
    end

    // Validate log_format
    let valid_formats = ["text"; "json"]
    var valid_format = false
    for format in valid_formats.values() do
      if format == config.log_format then
        valid_format = true
        break
      end
    end
    if not valid_format then
      return "Invalid configuration: log_format must be one of: text, json"
    end

    // Validate TLS configuration
    if config.tls_enabled then
      if config.tls_cert_file.size() == 0 then
        return "Invalid configuration: tls.cert_file is required when TLS is enabled"
      end
      if config.tls_key_file.size() == 0 then
        return "Invalid configuration: tls.key_file is required when TLS is enabled"
      end
    end

    None

// Simple JSON value class for configuration parsing
class _JsonValue
  """
  Represents a JSON value of various types.
  """
  var _string_val: (String | None) = None
  var _bool_val: (Bool | None) = None
  var _int_val: (I64 | None) = None
  var _obj_val: (Map[String, _JsonValue] | None) = None

  new create() =>
    None

  new from_string(s: String val) =>
    _string_val = consume s
  new from_bool(b: Bool) =>
    _bool_val = b
  new from_int(n: I64) =>
    _int_val = n
  new from_object(o: Map[String, _JsonValue] ref) =>
    _obj_val = o

  fun get_string(): (String | None) =>
    _string_val
  fun get_bool(): (Bool | None) =>
    _bool_val
  fun get_int(): (I64 | None) =>
    _int_val
  fun ref get_object(): (Map[String, _JsonValue] ref | None) =>
    _obj_val

class _JsonParser
  """
  Simple JSON parser for configuration files.
  Supports strings, booleans, integers, and objects.
  """
  let _input: String
  var _pos: USize = 0

  new create(input: String val) =>
    _input = consume input

  fun ref parse(): (Map[String, _JsonValue] | String) =>
    """
    Parse the JSON input and return a Map of values or an error string.
    """
    _skip_whitespace()
    if _pos >= _input.size() then
      return "Empty input"
    end

    try
      match _peek()?
      | '{' =>
        _advance()?
        _parse_object()
      else
        "Expected object at root"
      end
    else
      "Parse error"
    end

  fun ref _parse_object(): (Map[String, _JsonValue] ref | String) =>
    """
    Parse a JSON object: { "key": value, ... }
    """
    let obj = Map[String, _JsonValue]

    while true do
      _skip_whitespace()

      try
        if _pos >= _input.size() then
          return "Unexpected end of input in object"
        end

        // Check for end of object
        if _peek()? == '}' then
          _advance()?
          break
        end

        // Parse key
        let key = _parse_string_val()
        if key.size() == 0 then
          return "Empty key or parse error"
        end

        _skip_whitespace()

        // Expect colon
        try
          if _peek()? != ':' then
            return "Expected ':' after key"
          end
          _advance()?
        else
          return "Expected ':' after key"
        end

        _skip_whitespace()

        // Parse value
        let value = _parse_value()

        obj(key) = value

        _skip_whitespace()

        // Check for comma or end of object
        try
          match _peek()?
          | ',' =>
            _advance()?
          | '}' =>
            _advance()?
            break
          else
            return "Expected ',' or '}' after value"
          end
        else
          return "Unexpected end of input"
        end
      else
        return "Parse error in object"
      end
    end

    obj

  fun ref _parse_value(): _JsonValue =>
    """
    Parse a JSON value (string, boolean, number, or object).
    """
    _skip_whitespace()

    try
      if _pos >= _input.size() then
        return _JsonValue
      end

      match _peek()?
      | '"' =>
        _JsonValue.from_string(_parse_string_val())
      | '{' =>
        _advance()?
        match _parse_object()
        | let obj: Map[String, _JsonValue] ref => _JsonValue.from_object(obj)
        | let err: String => _JsonValue
        end
      | 't' =>
        _advance()?
        _JsonValue.from_bool(true)
      | 'f' =>
        _advance()?
        _JsonValue.from_bool(false)
      | '-' =>
        _JsonValue.from_int(_parse_number_val())
      | let c: U8 =>
        if (c >= '0') and (c <= '9') then
          _JsonValue.from_int(_parse_number_val())
        else
          _JsonValue
        end
      end
    else
      _JsonValue
    end

  fun ref _parse_string_val(): String val =>
    """
    Parse a JSON string value.
    """
    try
      if _peek()? != '"' then
        return ""
      end
      _advance()?

      var result = recover String end

      while _pos < _input.size() do
        let c = _advance()?

        match c
        | '"' =>
          // End of string
          break
        | '\\' =>
          // Escape sequence
          if _pos >= _input.size() then
            return ""
          end
          let escaped = _advance()?
          match escaped
          | '"' => result.push('"')
          | '\\' => result.push('\\')
          | '/' => result.push('/')
          | 'b' => result.push('\b')
          | 'f' => result.push('\f')
          | 'n' => result.push('\n')
          | 'r' => result.push('\r')
          | 't' => result.push('\t')
          else
            result.push(escaped)
          end
        else
          result.push(c)
        end
      end

      consume result
    else
      ""
    end

  fun ref _parse_string(): (String iso^ | String) =>
    """
    Parse a JSON string: "..."
    """
    try
      if _peek()? != '"' then
        return "Expected opening quote"
      end
      _advance()?

      var result = recover String end

      while _pos < _input.size() do
        let c = _advance()?

        match c
        | '"' =>
          // End of string
          break
        | '\\' =>
          // Escape sequence
          if _pos >= _input.size() then
            return "Unexpected end of input in escape sequence"
          end
          let escaped = _advance()?
          match escaped
          | '"' => result.push('"')
          | '\\' => result.push('\\')
          | '/' => result.push('/')
          | 'b' => result.push('')
          | 'f' => result.push('')
          | 'n' => result.push('
')
          | 'r' => result.push('')
          | 't' => result.push('	')
          else
            result.push(escaped)
          end
        else
          result.push(c)
        end
      end

      consume result
    else
      "Parse error in string"
    end

  fun ref _parse_true(): (Bool | String) =>
    """
    Parse 'true' literal.
    """
    if _input.at("true", _pos.isize()) then
      _pos = _pos + 4
      true
    else
      "Expected 'true'"
    end

  fun ref _parse_false(): (Bool | String) =>
    """
    Parse 'false' literal.
    """
    if _input.at("false", _pos.isize()) then
      _pos = _pos + 5
      false
    else
      "Expected 'false'"
    end

  fun ref _parse_number_val(): I64 =>
    """
    Parse a JSON number (integer only for simplicity).
    Returns 0 on error.
    """
    var start = _pos

    try
      // Handle negative sign
      if _peek()? == '-' then
        _advance()?
      end

      // Parse digits
      var has_digits = false
      while _pos < _input.size() do
        let c = _peek()?
        if (c >= '0') and (c <= '9') then
          has_digits = true
          _advance()?
        else
          break
        end
      end

      if not has_digits then
        return 0
      end

      // Extract the number string
      let num_str = _input.substring(start.isize(), _pos.isize())

      // Parse the integer
      try
        num_str.i64()?
      else
        0
      end
    else
      0
    end

  fun ref _skip_whitespace() =>
    """
    Skip whitespace characters.
    """
    try
      while _pos < _input.size() do
        match _peek()?
        | ' ' | '\t' | '\n' | '\r' => _advance()?
        else
          break
        end
      end
    end

  fun _peek(): U8? =>
    """
    Peek at the current character without advancing.
    """
    _input(_pos)?

  fun ref _advance(): U8? =>
    """
    Advance to the next character and return the current one.
    """
    let c = _input(_pos)?
    _pos = _pos + 1
    c
