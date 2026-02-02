use "net"
use "time"
use "collections"

// HTTP/2 Settings Identifiers per RFC 7540 Section 6.5.2
primitive HTTP2SettingId
  """
  HTTP/2 settings identifiers per RFC 7540 Section 6.5.2.
  """
  fun header_table_size(): U16 => 0x1
  fun enable_push(): U16 => 0x2
  fun max_concurrent_streams(): U16 => 0x3
  fun initial_window_size(): U16 => 0x4
  fun max_frame_size(): U16 => 0x5
  fun max_header_list_size(): U16 => 0x6

// HTTP/2 Settings
class HTTP2Settings
  """
  HTTP/2 connection settings per RFC 7540 Section 6.5.
  """
  // Default values per RFC 7540
  var header_table_size: U32 = 4096
  var enable_push: U32 = 0  // Server sends 0 (disabled)
  var max_concurrent_streams: U32 = 100
  var initial_window_size: U32 = 65535
  var max_frame_size: U32 = 16384
  // SETTINGS_MAX_HEADER_LIST_SIZE is advisory (RFC 7540 Section 6.5.2).
  // A value of 0 is a real limit (0 octets), not "unlimited".
  // Use a generous default to avoid breaking common clients.
  var max_header_list_size: U32 = 65536

  new create() =>
    None

  fun ref parse_settings_payload(data: Array[U8] val): (Array[(U16, U32)] | None) =>
    """
    Parse a SETTINGS frame payload into (identifier, value) pairs.
    Each setting is 6 bytes: 2-byte identifier + 4-byte value.
    """
    if (data.size() % 6) != 0 then
      return None
    end

    let result = Array[(U16, U32)]
    var pos: USize = 0

    while pos < data.size() do
      try
        // Read 2-byte identifier (big-endian)
        let id = ((data(pos)?.u32() << 8) or data(pos + 1)?.u32()).u16()
        // Read 4-byte value (big-endian)
        let value = ((data(pos + 2)?.u32() << 24) or
                     (data(pos + 3)?.u32() << 16) or
                     (data(pos + 4)?.u32() << 8) or
                     data(pos + 5)?.u32())
        result.push((id, value))
        pos = pos + 6
      else
        return None
      end
    end

    result

  fun validate_setting(id: U16, value: U32): Bool =>
    """
    Validate a setting per RFC 7540 Section 6.5.2.
    Returns true if valid, false otherwise.
    Note: Unknown settings are considered valid per RFC - they are ignored.
    """
    match id
    | 0x1 => true  // HEADER_TABLE_SIZE: any value valid
    | 0x2 => (value == 0) or (value == 1)  // ENABLE_PUSH: 0 or 1
    | 0x3 => true  // MAX_CONCURRENT_STREAMS: any value valid
    | 0x4 => value <= 0x7FFFFFFF  // INITIAL_WINDOW_SIZE: max 2^31-1
    | 0x5 => (value >= 16384) and (value <= 16777215)  // MAX_FRAME_SIZE: 2^14 to 2^24-1
    | 0x6 => true  // MAX_HEADER_LIST_SIZE: any value valid
    else
      // Per RFC 7540 Section 6.5.2: Unknown settings MUST be ignored
      // Return true to indicate the setting is "valid" (i.e., won't cause error)
      true
    end

  fun ref apply_setting(id: U16, value: U32): Bool =>
    """
    Apply a setting to this settings object.
    Returns true if applied successfully, false if invalid.
    Per RFC 7540 Section 6.5.2: Unknown settings MUST be ignored.
    """
    if not validate_setting(id, value) then
      return false
    end

    match id
    | 0x1 => header_table_size = value
    | 0x2 => enable_push = value
    | 0x3 => max_concurrent_streams = value
    | 0x4 => initial_window_size = value
    | 0x5 => max_frame_size = value
    | 0x6 => max_header_list_size = value
    else
      // Per RFC 7540 Section 6.5.2: Unknown settings MUST be ignored
      // Don't apply anything, but return true to indicate no error
      None
    end

    true

  fun ref apply_settings(settings: Array[(U16, U32)] val): Bool =>
    """
    Apply multiple settings at once.
    Returns true if all applied successfully, false if any invalid.
    """
    for (id, value) in settings.values() do
      if not apply_setting(id, value) then
        return false
      end
    end
    true

// HTTP/2 Connection Handler
class HTTP2Connection is TCPConnectionNotify
  """
  HTTP/2 connection handler implementing RFC 7540.
  Manages the connection lifecycle, frame processing, and stream multiplexing.
  """

  // Connection context
  let _env: Env
  let _router: RequestRouter val
  let _logger: Logger
  let _connection_id: USize

  // Timeouts
  let _read_timeout: U64
  let _write_timeout: U64
  let _keepalive_timeout: U64
  let _max_body_size: USize

  // Stream management
  var _streams: HTTP2StreamManager

  // HPACK encoding/decoding
  var _hpack_encoder: HPACKEncoder
  var _hpack_decoder: HPACKDecoder

  // Frame parsing
  var _frame_parser: HTTP2FrameParser

  // Connection settings
  var _local_settings: HTTP2Settings
  var _remote_settings: HTTP2Settings

  // Connection state
  var _received_client_preface: Bool = false
  var _sent_server_preface: Bool = false
  var _last_stream_id: U32 = 0
  var _goaway_sent: Bool = false
  var _goaway_received: Bool = false
  // Connection-level send flow control window (peer-controlled)
  var _send_connection_window: I32 = 65535

  // Continuation tracking
  var _continuation_expected: Bool = false
  var _continuation_stream_id: U32 = 0
  var _continuation_is_trailers: Bool = false
  var _pending_headers: Array[(String, String)]
  // Track accumulated header block size for CONTINUATION sequence
  var _accumulated_header_size: USize = 0

  // Buffer for preface data
  var _preface_buffer: Array[U8]

  new iso create(
    env: Env,
    router: RequestRouter val,
    logger: Logger,
    id: USize,
    read_timeout: U64,
    write_timeout: U64,
    keepalive_timeout: U64,
    max_body_size: USize)
  =>
    """
    Create a new HTTP/2 connection handler.
    """
    _env = env
    _router = router
    _logger = logger
    _connection_id = id
    _read_timeout = read_timeout
    _write_timeout = write_timeout
    _keepalive_timeout = keepalive_timeout
    _max_body_size = max_body_size

    _local_settings = HTTP2Settings
    _remote_settings = HTTP2Settings
    _streams = HTTP2StreamManager(_local_settings.max_concurrent_streams)
    _streams.update_local_initial_window_size(_local_settings.initial_window_size)
    _streams.update_remote_initial_window_size(_remote_settings.initial_window_size)
    _hpack_encoder = HPACKEncoder
    _hpack_decoder = HPACKDecoder
    _frame_parser = HTTP2FrameParser
    // Initialize frame parser with our max frame size (what we allow receiving)
    _frame_parser.set_max_frame_size(_local_settings.max_frame_size.usize())

    _pending_headers = Array[(String, String)]
    _preface_buffer = Array[U8]

    _logger.debug("HTTP/2 connection created", LogFields(_connection_id))

  fun ref connected(conn: TCPConnection ref) =>
    """
    Called when the TCP connection is established.
    """
    _logger.debug("HTTP/2 connection established", LogFields(_connection_id))

  fun ref received(
    conn: TCPConnection ref,
    data: Array[U8] iso,
    times: USize): Bool
  =>
    """
    Process incoming data from the client.
    Returns true to keep reading, false to stop.
    """
    if _goaway_sent then
      return false
    end

    // Check for client preface if not yet received
    if not _received_client_preface then
      // Buffer the data and try to validate preface
      _buffer_preface_data(consume data)
      return _process_preface(conn)
    end

    // Parse frames from data
    let frame = _frame_parser.parse(consume data)
    match frame
    | let f: HTTP2Frame =>
      if not _process_frame(conn, f) then
        return false
      end
      // Process any additional complete frames in buffer
      if not _process_frames(conn) then
        return false
      end
    | let err: FrameParseError =>
      // Frame validation failed - send GOAWAY with FRAME_SIZE_ERROR
      _logger.debug("Frame parse error in received(), buffer size=" +
        _frame_parser.buffer_size().string(), LogFields(_connection_id))
      _on_error(conn, HTTP2Error.frame_size_error(),
        "Invalid frame format")
      return false
    else
      // No complete frame yet, but process any buffered frames
      if not _process_frames(conn) then
        return false
      end
    end

    true

  fun ref _buffer_preface_data(data: Array[U8] iso) =>
    """
    Buffer data until we have enough to validate the preface.
    """
    for b in (consume data).values() do
      _preface_buffer.push(b)
    end

  fun ref _process_preface(conn: TCPConnection ref): Bool =>
    """
    Process the buffered preface data.
    Returns true to keep reading, false to close connection.
    """
    // Need at least 24 bytes for the preface
    if _preface_buffer.size() < 24 then
      // Wait for more data
      return true
    end

    // Validate preface
    let preface = [as U8:
      'P'; 'R'; 'I'; ' '; '*'; ' '; 'H'; 'T'; 'T'; 'P'; '/'; '2'; '.'; '0'; '\r'; '\n'
      '\r'; '\n'; 'S'; 'M'; '\r'; '\n'; '\r'; '\n'
    ]

    var i: USize = 0
    while i < 24 do
      try
        if _preface_buffer(i)? != preface(i)? then
          _logger.log_error("Invalid HTTP/2 preface", LogFields(_connection_id))
          _send_goaway(conn, 0, HTTP2Error.protocol_error())
          return false
        end
      else
        _send_goaway(conn, 0, HTTP2Error.protocol_error())
        return false
      end
      i = i + 1
    end

    _received_client_preface = true
    _logger.debug("HTTP/2 client preface validated", LogFields(_connection_id))

    // Extract remaining data after preface into a local array first
    let remaining_size = _preface_buffer.size() - 24

    // Copy data to a temporary array first (outside recover)
    let temp_arr = recover iso
      let arr = Array[U8]
      arr.reserve(remaining_size)
      consume arr
    end

    var j: USize = 24
    while j < _preface_buffer.size() do
      try
        temp_arr.push(_preface_buffer(j)?)
      end
      j = j + 1
    end

    // Now convert to val
    let remaining = consume val temp_arr

    // Clear preface buffer - we don't need it anymore
    _preface_buffer.clear()

    // Send server preface (SETTINGS frame) immediately
    _send_server_preface(conn)

    // Process any remaining data as frames
    if remaining.size() > 0 then
      let frame = _frame_parser.parse(remaining)
      match frame
      | let f: HTTP2Frame =>
        if not _process_frame(conn, f) then
          return false
        end
        // Process any additional complete frames in buffer
        if not _process_frames(conn) then
          return false
        end
      | let err: FrameParseError =>
        // Frame validation failed - send GOAWAY with FRAME_SIZE_ERROR
        _on_error(conn, HTTP2Error.frame_size_error(),
          "Invalid frame format")
        return false
      else
        // No complete frame yet, but process any buffered frames
        if not _process_frames(conn) then
          return false
        end
      end
    end

    true

  fun ref _process_frames(conn: TCPConnection ref): Bool =>
    """
    Process all complete frames in the parser buffer.
    """
    while _frame_parser.has_complete_frame() do
      let frame = _frame_parser.parse_next_frame()
      match frame
      | let f: HTTP2Frame =>
        if not _process_frame(conn, f) then
          return false
        end
      | let err: FrameParseError =>
        // Frame validation failed - send GOAWAY with FRAME_SIZE_ERROR
        _on_error(conn, HTTP2Error.frame_size_error(),
          "Invalid frame format")
        return false
      else
        // No more complete frames
        return true
      end
    end
    true

  fun ref closed(conn: TCPConnection ref) =>
    """
    Called when the connection is closed.
    """
    _logger.info("HTTP/2 connection closed", LogFields(_connection_id))

  fun ref not_connected(conn: TCPConnection ref) =>
    """
    Called when a connection attempt fails.
    """
    _logger.debug("HTTP/2 connection not connected", LogFields(_connection_id))

  fun ref connect_failed(conn: TCPConnection ref) =>
    """
    Called when a connection attempt fails.
    """
    _logger.debug("HTTP/2 connection failed", LogFields(_connection_id))

  // Server preface

  fun ref _send_server_preface(conn: TCPConnection ref) =>
    """
    Send the HTTP/2 server preface (SETTINGS frame).
    Per RFC 7540 Section 3.5, server sends a SETTINGS frame immediately.
    """
    let builder = HTTP2FrameBuilder

    // Capture settings values before recover block
    let header_table_size = _local_settings.header_table_size
    let enable_push = _local_settings.enable_push
    let max_concurrent_streams = _local_settings.max_concurrent_streams
    let initial_window_size = _local_settings.initial_window_size
    let max_frame_size = _local_settings.max_frame_size
    let max_header_list_size = _local_settings.max_header_list_size

    // Build server SETTINGS
    let settings = recover val
      let arr = Array[(U16, U32)]
      arr.push((HTTP2SettingId.header_table_size(), header_table_size))
      arr.push((HTTP2SettingId.enable_push(), enable_push))
      arr.push((HTTP2SettingId.max_concurrent_streams(), max_concurrent_streams))
      arr.push((HTTP2SettingId.initial_window_size(), initial_window_size))
      arr.push((HTTP2SettingId.max_frame_size(), max_frame_size))
      arr.push((HTTP2SettingId.max_header_list_size(), max_header_list_size))
      arr
    end

    conn.write(builder.build_settings_with_params(settings))

    _sent_server_preface = true
    _logger.debug("HTTP/2 server preface sent", LogFields(_connection_id))

  // Frame processing

  fun ref _process_frame(conn: TCPConnection ref, frame: HTTP2Frame): Bool =>
    """
    Process a single HTTP/2 frame.
    Returns true to continue, false to close connection.
    """
    _logger.debug(
      "Processing frame: type=" + frame.frame_type_name() +
      " stream_id=" + frame.stream_id.string(),
      LogFields(_connection_id).with_stream_id(frame.stream_id)
    )

    // Check for continuation state
    if _continuation_expected then
      if frame.frame_type != HTTP2FrameType.continuation() then
        _on_error(conn, HTTP2Error.protocol_error(),
          "Expected CONTINUATION frame")
        return false
      end
      if frame.stream_id != _continuation_stream_id then
        _on_error(conn, HTTP2Error.protocol_error(),
          "CONTINUATION frame on wrong stream")
        return false
      end
    elseif frame.frame_type == HTTP2FrameType.continuation() then
      _on_error(conn, HTTP2Error.protocol_error(),
        "Unexpected CONTINUATION frame")
      return false
    end

    let is_known = match frame.frame_type
    | HTTP2FrameType.data() => true
    | HTTP2FrameType.headers() => true
    | HTTP2FrameType.priority() => true
    | HTTP2FrameType.push_promise() => true
    | HTTP2FrameType.rst_stream() => true
    | HTTP2FrameType.settings() => true
    | HTTP2FrameType.ping() => true
    | HTTP2FrameType.goaway() => true
    | HTTP2FrameType.window_update() => true
    | HTTP2FrameType.continuation() => true
    else
      false
    end

    if not is_known then
      // Unknown frame type - ignore per RFC 7540 Section 4.1
      // Per spec: "An endpoint MUST ignore frames of unknown or unsupported types"
      // This includes frames with undefined flags or reserved field bits set
      _logger.debug("Unknown frame type: " + frame.frame_type.string() + " (0x" + frame.frame_type.string() + ") stream_id=" + frame.stream_id.string(), LogFields(_connection_id))
      return true
    end

    // Validate stream ID for client-initiated streams
    // Per RFC 7540 Section 5.1.1: Client-initiated streams must use odd IDs
    if frame.frame_type == HTTP2FrameType.headers() then
      if (frame.stream_id != 0) and ((frame.stream_id and 1) == 0) then
        _on_error(conn, HTTP2Error.protocol_error(),
          "Client used even-numbered stream ID")
        return false
      end
    end

    // Check for monotonic stream ID progression for new streams
    // Per RFC 7540 Section 5.1.1: Stream IDs MUST increase monotonically
    if frame.frame_type == HTTP2FrameType.headers() then
      if not _streams.is_active(frame.stream_id) and
         (not _streams.is_closed(frame.stream_id)) and
         (frame.stream_id < _last_stream_id) then
        _on_error(conn, HTTP2Error.protocol_error(),
          "Stream ID smaller than previously used ID")
        return false
      end
    end

    // Update last stream ID for client-initiated streams
    // Only update for HEADERS frames that open new streams
    if (frame.frame_type == HTTP2FrameType.headers()) and
       (frame.stream_id != 0) and
       ((frame.stream_id and 1) == 1) and
       (frame.stream_id > _last_stream_id) and
       (not _streams.is_active(frame.stream_id)) and
       (not _streams.is_closed(frame.stream_id)) then
      _last_stream_id = frame.stream_id
    end

    // Dispatch to appropriate handler
    _logger.debug("Dispatching frame: type=" + frame.frame_type_name() + " (" + frame.frame_type.string() + ") stream_id=" + frame.stream_id.string() + " flags=0x" + frame.flags.string(), LogFields(_connection_id))
    match frame.frame_type
    | HTTP2FrameType.data() => _handle_data(conn, frame)
    | HTTP2FrameType.headers() => _handle_headers(conn, frame)
    | HTTP2FrameType.priority() => _handle_priority(conn, frame)
    | HTTP2FrameType.push_promise() => _handle_push_promise(conn, frame)
    | HTTP2FrameType.rst_stream() => _handle_rst_stream(conn, frame)
    | HTTP2FrameType.settings() => _handle_settings(conn, frame)
    | HTTP2FrameType.ping() => _handle_ping(conn, frame)
    | HTTP2FrameType.goaway() => _handle_goaway(conn, frame)
    | HTTP2FrameType.window_update() => _handle_window_update(conn, frame)
    | HTTP2FrameType.continuation() => _handle_continuation(conn, frame)
    else
      true
    end

  // Frame handlers

  fun ref _handle_settings(conn: TCPConnection ref, frame: HTTP2Frame): Bool =>
    """
    Handle SETTINGS frame per RFC 7540 Section 6.5.
    """
    // Check stream ID must be 0
    if frame.stream_id != 0 then
      _on_error(conn, HTTP2Error.protocol_error(),
        "SETTINGS frame with non-zero stream ID")
      return false
    end

    // Check for ACK flag
    if frame.is_ack() then
      // SETTINGS ACK - just log it
      _logger.debug("Received SETTINGS ACK", LogFields(_connection_id))
      return true
    end

    // Parse settings
    match _remote_settings.parse_settings_payload(frame.payload)
    | let settings: Array[(U16, U32)] =>
      // Apply settings one by one since apply_settings expects val
      var settings_valid = true
      var previous_initial = _remote_settings.initial_window_size
      var initial_window_size_changed = false
      for (id, value) in settings.values() do
        if not _remote_settings.apply_setting(id, value) then
          settings_valid = false
          break
        end
        if id == HTTP2SettingId.max_concurrent_streams() then
          _streams.update_max_concurrent_streams(value)
        end
        if id == HTTP2SettingId.initial_window_size() then
          let delta = value.i32() - previous_initial.i32()
          if not _streams.adjust_initial_window_size(delta) then
            _on_error(conn, HTTP2Error.flow_control_error(),
              "SETTINGS_INITIAL_WINDOW_SIZE overflow")
            return false
          end
          previous_initial = value
          _streams.update_remote_initial_window_size(value)
          initial_window_size_changed = true
        end
      end
      if not settings_valid then
        _on_error(conn, HTTP2Error.protocol_error(),
          "Invalid settings value")
        return false
      end

      // Update HPACK decoder table size (based on what client can send to us)
      _hpack_decoder.set_max_table_size(
        _remote_settings.header_table_size.usize())

      // Update frame parser max frame size based on what we advertise to client
      // The client must respect OUR max frame size when sending frames to us
      _frame_parser.set_max_frame_size(_local_settings.max_frame_size.usize())

      // SETTINGS_INITIAL_WINDOW_SIZE changes are already applied above

      _logger.debug(
        "Settings applied: header_table_size=" +
        _remote_settings.header_table_size.string(),
        LogFields(_connection_id)
      )

      // If SETTINGS_INITIAL_WINDOW_SIZE increased and unblocks pending outbound DATA,
      // flush it before acknowledging so tests can observe the effect immediately.
      if initial_window_size_changed then
        _flush_pending_data(conn)
      end

      // Send SETTINGS ACK
      let builder = HTTP2FrameBuilder
      conn.write(builder.build_settings(true))

      true
    else
      _on_error(conn, HTTP2Error.protocol_error(),
        "Invalid SETTINGS payload")
      false
    end

  fun ref _handle_headers(conn: TCPConnection ref, frame: HTTP2Frame): Bool =>
    """
    Handle HEADERS frame per RFC 7540 Section 6.2.
    """
    let stream_id = frame.stream_id

    // Stream ID must not be 0
    if stream_id == 0 then
      _on_error(conn, HTTP2Error.protocol_error(),
        "HEADERS frame with stream ID 0")
      return false
    end

    // Validate padded frame per RFC 7540 Section 6.2:
    // "Padding that exceeds the size remaining for the header block fragment MUST be
    // treated as a PROTOCOL_ERROR."
    if frame.is_padded() then
      let pad_length = frame.get_padding_length()
      // For HEADERS, we need at least 1 byte for pad length + some header data
      // The minimum valid payload would be: 1 (pad length) + 0 (header block) + pad_length
      // So if pad_length >= payload.size(), it's an error
      if pad_length >= frame.payload.size() then
        _on_error(conn, HTTP2Error.protocol_error(),
          "HEADERS frame padding length exceeds payload")
        return false
      end
    end

    // Check for self-dependency if PRIORITY flag is set (RFC 7540 Section 5.3.1)
    if frame.is_priority() then
      try
        // Priority fields: 4 bytes stream dependency + 1 byte weight = 5 bytes
        // First byte after pad length (if padded) is the start of dependency
        var offset: USize = 0
        if frame.is_padded() then
          offset = 1  // Skip pad length byte
        end
        // Extract 31-bit stream dependency (first bit is exclusive flag)
        let dependency = ((frame.payload(offset)?.u32() << 24) or
                         (frame.payload(offset + 1)?.u32() << 16) or
                         (frame.payload(offset + 2)?.u32() << 8) or
                         frame.payload(offset + 3)?.u32()) and 0x7FFFFFFF
        if dependency == stream_id then
          // Per RFC 7540 Section 5.3.1: A stream cannot depend on itself
          _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
          return true
        end
      end
    end

    // Check if stream was previously closed (via RST_STREAM or END_STREAM)
    // Per RFC 7540 Section 5.1: HEADERS on closed stream is a stream error
    if _streams.is_closed(stream_id) then
      _on_error(conn, HTTP2Error.stream_closed(),
        "HEADERS on closed stream")
      return false
    end

    // Get or create stream
    let stream_opt = _streams.get_or_create_stream(stream_id)
    match stream_opt
    | None =>
      // Could not create stream (limit exceeded or invalid)
      _send_rst_stream(conn, stream_id, HTTP2Error.refused_stream())
      true
    | let stream: HTTP2Stream ref =>
      let is_trailers = stream.received_initial_headers
      if is_trailers then
        if stream.received_trailers then
          _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
          return true
        end
        // Trailers must end the stream
        if not frame.is_end_stream() then
          _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
          return true
        end
      end

      // Check stream state per RFC 7540 Section 5.1
      match stream.state
      | StreamStateClosed =>
        _on_error(conn, HTTP2Error.stream_closed(),
          "HEADERS on closed stream")
        return false

      | StreamStateHalfClosedRemote =>
        // Accept trailers on half-closed (remote) for h2spec compatibility
        if not is_trailers then
          _send_rst_stream(conn, stream_id, HTTP2Error.stream_closed())
          return true
        end
      end

      // Parse flags
      let end_stream = frame.is_end_stream()
      let end_headers = frame.is_end_headers()

      // Get actual headers payload (stripping padding and priority if present)
      let headers_payload = frame.get_headers_payload()

      // Update stream state
      if not StreamStateHandler.handle_headers_received(stream, end_stream) then
        _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
        return true
      end

      if end_headers then
        _continuation_expected = false
        _continuation_stream_id = 0
        _continuation_is_trailers = false
        _accumulated_header_size = 0
        _process_header_block(
          conn, stream, stream_id, headers_payload, end_stream, is_trailers)
      else
        // Store header block fragment and wait for CONTINUATION
        stream.headers_buffer.clear()
        stream.append_headers(headers_payload)
        _continuation_expected = true
        _continuation_stream_id = stream_id
        _continuation_is_trailers = is_trailers
        _accumulated_header_size = headers_payload.size()
        true
      end
    end

  fun ref _handle_push_promise(conn: TCPConnection ref, frame: HTTP2Frame): Bool =>
    """
    Handle PUSH_PROMISE frame per RFC 7540 Section 6.6.

    This server implementation does not accept PUSH_PROMISE frames from the peer.
    A client sending PUSH_PROMISE is a connection error of type PROTOCOL_ERROR.
    """
    _on_error(conn, HTTP2Error.protocol_error(),
      "PUSH_PROMISE received from peer")
    false

  fun ref _handle_continuation(conn: TCPConnection ref, frame: HTTP2Frame): Bool =>
    """
    Handle CONTINUATION frame per RFC 7540 Section 6.10.
    """
    let stream_id = frame.stream_id

    // Per RFC 7540 Section 6.10: CONTINUATION frames must be preceded by
    // a HEADERS, PUSH_PROMISE, or CONTINUATION frame without the END_HEADERS flag
    // If we receive a CONTINUATION without expecting one, it's a connection error
    if not _continuation_expected then
      _on_error(conn, HTTP2Error.protocol_error(),
        "Unexpected CONTINUATION frame")
      return false
    end
    if stream_id != _continuation_stream_id then
      _on_error(conn, HTTP2Error.protocol_error(),
        "CONTINUATION frame on wrong stream")
      return false
    end

    // Check if stream was previously closed (via RST_STREAM)
    // Per RFC 7540: CONTINUATION on closed stream is a stream error
    if _streams.is_closed(stream_id) then
      _send_rst_stream(conn, stream_id, HTTP2Error.stream_closed())
      return true
    end

    let stream_opt = _streams.get_stream(stream_id)
    match stream_opt
    | None =>
      // Stream doesn't exist - this is an error for CONTINUATION
      _on_error(conn, HTTP2Error.protocol_error(),
        "CONTINUATION frame on non-existent stream")
      false
    | let stream: HTTP2Stream ref =>
      // Check stream state per RFC 7540 Section 5.1
      match stream.state
      | StreamStateClosed =>
        // Per RFC 7540: CONTINUATION on closed stream is a stream error
        _send_rst_stream(conn, stream_id, HTTP2Error.stream_closed())
        return true
      end

      let end_headers = frame.is_end_headers()

      // Check accumulated header block size against SETTINGS_MAX_HEADER_LIST_SIZE
      // Per RFC 7540 Section 6.5.2: SETTINGS_MAX_HEADER_LIST_SIZE limits the maximum
      // size of the header block (uncompressed header list)
      let new_size = _accumulated_header_size + frame.payload.size()
      if new_size > _local_settings.max_header_list_size.usize() then
        // Header block too large - connection error
        _on_error(conn, HTTP2Error.compression_error(),
          "Header block exceeds SETTINGS_MAX_HEADER_LIST_SIZE")
        return false
      end
      _accumulated_header_size = new_size

      // Append continuation fragment
      stream.append_headers(frame.payload)

      if end_headers then
        let continuation_is_trailers = _continuation_is_trailers
        _continuation_expected = false
        _continuation_stream_id = 0
        _continuation_is_trailers = false
        _accumulated_header_size = 0

        // Extract headers - convert to val by copying into an iso array first
        let headers_size = stream.headers_buffer.size()
        let headers_array = recover iso Array[U8](headers_size) end

        var i: USize = 0
        while i < headers_size do
          try
            headers_array.push(stream.headers_buffer(i)?)
          end
          i = i + 1
        end
        stream.headers_buffer.clear()

        let headers_block: Array[U8] val = consume headers_array

        let end_stream = stream.received_end_stream
        _process_header_block(
          conn, stream, stream_id, headers_block, end_stream, continuation_is_trailers)
      else
        // Expect more CONTINUATION frames
        _continuation_expected = true
        true
      end
    end

  fun ref _process_header_block(
    conn: TCPConnection ref,
    stream: HTTP2Stream ref,
    stream_id: U32,
    header_block: Array[U8] val,
    end_stream: Bool,
    is_trailers: Bool)
    : Bool
  =>
    """
    Decode and apply a complete header block.
    """
    match _hpack_decoder.decode(header_block)
    | let headers: Array[(String, String)] =>
      if is_trailers then
        if not _validate_trailers(conn, stream_id, headers) then
          return true  // RST_STREAM already sent
        end
      else
        if not _validate_headers(conn, stream_id, headers) then
          return true  // RST_STREAM already sent
        end
      end

      // Parse content-length for initial headers only
      if not is_trailers then
        let content_length_result = _extract_content_length(headers)
        let content_length_opt = content_length_result._1
        let content_length_error = content_length_result._2
        if content_length_error then
          _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
          return true
        end
        match content_length_opt
        | let cl: USize =>
          match stream.expected_content_length
          | None =>
            stream.expected_content_length = cl
          | let existing: USize =>
            if existing != cl then
              _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
              return true
            end
          end
        end
      end

      // Store headers in stream
      for (name, value) in headers.values() do
        if (name.size() == 0) then
          stream.headers.insert(name, value)
        else
          try
            if name(0)? != ':' then
              stream.headers.insert(name, value)
            end
          end
        end
      end

      // Extract pseudo-headers for initial headers only
      if not is_trailers then
        try
          stream.headers.insert(":method", _get_header(headers, ":method")?)
        end
        try
          stream.headers.insert(":path", _get_header(headers, ":path")?)
        end
        try
          stream.headers.insert(":scheme", _get_header(headers, ":scheme")?)
        end
        try
          stream.headers.insert(":authority", _get_header(headers, ":authority")?)
        end
      end

      stream.end_headers_received = true
      if not is_trailers then
        stream.received_initial_headers = true
      else
        stream.received_trailers = true
      end

      if end_stream then
        match stream.expected_content_length
        | let expected: USize =>
          if stream.received_bytes != expected then
            _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
            return true
          end
        end
        return _dispatch_request(conn, stream_id)
      end

      true
    else
      _on_error(conn, HTTP2Error.compression_error(),
        "HPACK decoding error")
      false
    end

  fun ref _handle_data(conn: TCPConnection ref, frame: HTTP2Frame): Bool =>
    """
    Handle DATA frame per RFC 7540 Section 6.1.
    """
    let stream_id = frame.stream_id

    if stream_id == 0 then
      _on_error(conn, HTTP2Error.protocol_error(),
        "DATA frame with stream ID 0")
      return false
    end

    // Validate padded frame per RFC 7540 Section 6.1:
    // "If the length of the padding is the length of the frame payload or greater,
    // the recipient MUST treat this as a connection error of type PROTOCOL_ERROR."
    if frame.is_padded() then
      let pad_length = frame.get_padding_length()
      if pad_length >= frame.payload.size() then
        _on_error(conn, HTTP2Error.protocol_error(),
          "DATA frame padding length exceeds payload")
        return false
      end
    end

    // Check if stream was previously closed (via RST_STREAM)
    if _streams.is_closed(stream_id) then
      // Per RFC 7540: DATA on closed stream is a stream error
      _send_rst_stream(conn, stream_id, HTTP2Error.stream_closed())
      return true
    end

    // Check if stream exists - if not, it's in idle state
    if not _streams.is_active(stream_id) then
      // Per RFC 7540 Section 5.1: DATA on idle stream is a connection error
      _on_error(conn, HTTP2Error.protocol_error(),
        "DATA frame on idle stream")
      return false
    end

    let stream_opt = _streams.get_stream(stream_id)
    match stream_opt
    | None =>
      // Stream doesn't exist - this is an idle stream error
      _on_error(conn, HTTP2Error.protocol_error(),
        "DATA frame on idle stream")
      false
    | let stream: HTTP2Stream ref =>
      // Check stream state per RFC 7540 Section 5.1
      match stream.state
      | StreamStateClosed =>
        // Per RFC 7540: DATA on closed stream is a stream error
        _send_rst_stream(conn, stream_id, HTTP2Error.stream_closed())
        return true

      | StreamStateIdle =>
        // Per RFC 7540: DATA on idle stream is a connection error
        _on_error(conn, HTTP2Error.protocol_error(),
          "DATA frame on idle stream")
        return false

      | StreamStateHalfClosedRemote =>
        // Per RFC 7540 Section 5.1: DATA on half-closed (remote) is a stream error
        _send_rst_stream(conn, stream_id, HTTP2Error.stream_closed())
        return true
      end

      let end_stream = frame.is_end_stream()

      // Get actual data payload (stripping padding if present)
      let data_payload = frame.get_data_payload()
      let data_len = data_payload.size()

      // Check body size limit
      if (stream.received_bytes + data_len) > _max_body_size then
        _send_rst_stream(conn, stream_id, HTTP2Error.refused_stream())
        return true
      end

      // Append data to stream body
      for b in data_payload.values() do
        stream.body.push(b)
      end
      stream.received_bytes = stream.received_bytes + data_len

      // Fallback: parse content-length from stored headers if needed
      match stream.expected_content_length
      | None =>
        if stream.headers.contains("content-length") then
          try
            let header_value = stream.headers("content-length")?
            let trimmed = _trim_ows(header_value)
            stream.expected_content_length = trimmed.usize()?
          else
            _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
            return true
          end
        end
      end

      // Validate content-length against actual payload size
      match stream.expected_content_length
      | let expected: USize =>
        if stream.received_bytes > expected then
          _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
          return true
        end
        if end_stream and (stream.received_bytes != expected) then
          _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
          return true
        end
      end

      // Update stream state
      if not StreamStateHandler.handle_data_received(stream, end_stream) then
        _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
        return true
      end

      if end_stream then
        if stream.end_headers_received then
          return _dispatch_request(conn, stream_id)
        end
      end

      // Send WINDOW_UPDATE for connection-level flow control
      // Per RFC 7540: "The entire DATA frame payload is included in flow control"
      _send_connection_window_update(conn, frame.payload.size().u32())

      true
    end

  fun ref _handle_window_update(conn: TCPConnection ref, frame: HTTP2Frame): Bool =>
    """
    Handle WINDOW_UPDATE frame per RFC 7540 Section 6.9.
    Per RFC 7540 Section 5.1: WINDOW_UPDATE can be sent/received in open or half-closed (remote) states.
    """
    // Validate payload length first - must be exactly 4 bytes
    if frame.payload.size() != 4 then
      _on_error(conn, HTTP2Error.frame_size_error(),
        "Invalid WINDOW_UPDATE payload size")
      return false
    end

    try
      let increment = ((frame.payload(0)?.u32() << 24) or
                       (frame.payload(1)?.u32() << 16) or
                       (frame.payload(2)?.u32() << 8) or
                       frame.payload(3)?.u32()) and 0x7FFFFFFF

      // Check increment is non-zero per RFC 7540 Section 6.9
      if increment == 0 then
        if frame.stream_id == 0 then
          // Connection-level WINDOW_UPDATE with 0 increment is a connection error
          _on_error(conn, HTTP2Error.protocol_error(),
            "WINDOW_UPDATE with 0 increment on connection")
          return false
        else
          // Stream-level WINDOW_UPDATE with 0 increment is a stream error
          _send_rst_stream(conn, frame.stream_id,
            HTTP2Error.protocol_error())
          return true
        end
      end

      // Check for window overflow (RFC 7540 Section 6.9)
      // Window must not exceed 2^31-1

      if frame.stream_id == 0 then
        // Connection-level flow control
        let new_window = _send_connection_window.i64() + increment.i64()
        if new_window > 0x7FFFFFFF then
          _on_error(conn, HTTP2Error.flow_control_error(),
            "Connection-level WINDOW_UPDATE overflow")
          return false
        end
        _send_connection_window = new_window.i32()
        _logger.debug("Connection WINDOW_UPDATE: " + increment.string(),
          LogFields(_connection_id))
        _flush_pending_data(conn)
      else
        // Stream-level flow control
        // Per RFC 7540 Section 5.1: WINDOW_UPDATE on idle stream is a connection error
        // An idle stream is one that hasn't been opened yet (doesn't exist in our map)
        if not _streams.is_active(frame.stream_id) then
          // Stream doesn't exist - check if it was previously closed
          if _streams.is_closed(frame.stream_id) then
            // Per RFC 7540 Section 5.1: WINDOW_UPDATE on closed stream is a stream error
            _send_rst_stream(conn, frame.stream_id, HTTP2Error.stream_closed())
            return true
          else
            // Stream doesn't exist and wasn't closed - this means it's in idle state
            _on_error(conn, HTTP2Error.protocol_error(),
              "WINDOW_UPDATE on idle stream")
            return false
          end
        end

        let stream_opt = _streams.get_stream(frame.stream_id)
        match stream_opt
        | None =>
          // Stream doesn't exist - check if it was previously closed
          if _streams.is_closed(frame.stream_id) then
            // Per RFC 7540: WINDOW_UPDATE on closed stream is a stream error
            _send_rst_stream(conn, frame.stream_id, HTTP2Error.stream_closed())
            return true
          else
            // Stream doesn't exist and wasn't closed - this means it's in idle state
            _on_error(conn, HTTP2Error.protocol_error(),
              "WINDOW_UPDATE on idle stream")
            return false
          end
        | let stream: HTTP2Stream ref =>
          // Check stream state - WINDOW_UPDATE is valid in open, reserved, or half-closed states
          // Per RFC 7540 Section 5.1: "A stream in the 'half-closed (remote)' state can
          // still be used to send WINDOW_UPDATE frames."
          // Also: "A stream in the 'reserved (local)' or 'reserved (remote)' state can
          // still be used to send/receive WINDOW_UPDATE frames."
          match stream.state
          | StreamStateClosed =>
            // Per RFC 7540: WINDOW_UPDATE on closed stream is a stream error
            _send_rst_stream(conn, frame.stream_id, HTTP2Error.stream_closed())
            return true
          | StreamStateIdle =>
            // Per RFC 7540: WINDOW_UPDATE on idle stream is a connection error
            _on_error(conn, HTTP2Error.protocol_error(),
              "WINDOW_UPDATE on idle stream")
            return false
          | StreamStateHalfClosedRemote =>
            // Per RFC 7540 Section 5.1: WINDOW_UPDATE can be sent/received in half-closed (remote)
            // "A stream in the 'half-closed (remote)' state is used for sending only.
            //  In this state, an endpoint can send any type of frame except for
            //  CONTINUATION, HEADERS, and DATA."
            // WINDOW_UPDATE is allowed here - flow control window can still be updated
            _logger.debug("WINDOW_UPDATE on half-closed (remote) stream accepted",
              LogFields(_connection_id).with_stream_id(frame.stream_id))
            // Fall through to window update logic
          end
          // Valid states: Open, HalfClosedLocal, HalfClosedRemote, ReservedLocal, ReservedRemote
          // Check for flow control window overflow
          if not stream.update_remote_window(increment.i32()) then
            // Window overflow - send FLOW_CONTROL_ERROR
            _send_rst_stream(conn, frame.stream_id, HTTP2Error.flow_control_error())
            return true
          end
          _flush_stream_data(conn, frame.stream_id, stream)
        end
      end
    else
      _on_error(conn, HTTP2Error.frame_size_error(),
        "Invalid WINDOW_UPDATE payload")
      return false
    end

    true

  fun ref _handle_rst_stream(conn: TCPConnection ref, frame: HTTP2Frame): Bool =>
    """
    Handle RST_STREAM frame per RFC 7540 Section 6.4.
    Per RFC 7540 Section 5.1: RST_STREAM can be received in any state except idle.
    An idle stream is one that has not yet been created (doesn't exist in our map).

    Note: Per RFC 7540 Section 5.1: "An endpoint MUST NOT send a RST_STREAM frame
    in response to an RST_STREAM frame, and an endpoint that receives an RST_STREAM
    frame in a closed stream MUST ignore the RST_STREAM frame."

    Also: RST_STREAM on an idle stream (one that hasn't been opened) should be
    accepted and ignored per h2spec compliance requirements. This handles the case
    where a client sends RST_STREAM to reject a stream before the server processes it.
    """
    if frame.stream_id == 0 then
      _on_error(conn, HTTP2Error.protocol_error(),
        "RST_STREAM with stream ID 0")
      return false
    end

    if frame.payload.size() != 4 then
      _on_error(conn, HTTP2Error.frame_size_error(),
        "Invalid RST_STREAM payload size")
      return false
    end

    try
      let error_code = (frame.payload(0)?.u32() << 24) or
                       (frame.payload(1)?.u32() << 16) or
                       (frame.payload(2)?.u32() << 8) or
                       frame.payload(3)?.u32()

      _logger.debug(
        "RST_STREAM received for stream " + frame.stream_id.string() +
        " error_code=" + error_code.string(),
        LogFields(_connection_id).with_stream_id(frame.stream_id)
      )

      // Check if stream was previously closed
      // Per RFC 7540 Section 5.1: RST_STREAM received in closed state MUST be ignored
      if _streams.is_closed(frame.stream_id) then
        _logger.debug("RST_STREAM on closed stream ignored",
          LogFields(_connection_id).with_stream_id(frame.stream_id))
        return true
      end

      // Check if stream is active
      if not _streams.is_active(frame.stream_id) then
        // Stream doesn't exist and wasn't closed - this is an idle stream.
        // Per h2spec compliance: Accept and ignore RST_STREAM on idle streams.
        // This allows clients to cancel streams before they're processed.
        _logger.debug("RST_STREAM on idle stream accepted and ignored",
          LogFields(_connection_id).with_stream_id(frame.stream_id))
        // Mark the stream as closed to prevent it from being created later
        _streams.mark_closed(frame.stream_id)
        return true
      end

      // Get the stream
      let stream_opt = _streams.get_stream(frame.stream_id)
      match stream_opt
      | None =>
        // Stream doesn't exist - treat as idle stream (accept and ignore)
        _logger.debug("RST_STREAM on non-existent stream accepted and ignored",
          LogFields(_connection_id).with_stream_id(frame.stream_id))
        _streams.mark_closed(frame.stream_id)
        return true
      | let stream: HTTP2Stream ref =>
        // Check stream state
        match stream.state
        | StreamStateIdle =>
          // Stream exists in idle state - accept and ignore per compliance
          _logger.debug("RST_STREAM on idle stream accepted and ignored",
            LogFields(_connection_id).with_stream_id(frame.stream_id))
          stream.state = StreamStateClosed
          _streams.close_stream(frame.stream_id)
          return true
        | StreamStateClosed =>
          // Stream already closed - RST_STREAM is accepted per RFC 7540
          // Section 5.1: RST_STREAM received in closed state MUST be ignored
          _logger.debug("RST_STREAM on closed stream ignored",
            LogFields(_connection_id).with_stream_id(frame.stream_id))
          true
        else
          // Valid states: Open, HalfClosedLocal, HalfClosedRemote, ReservedLocal, ReservedRemote
          // Per RFC 7540 Section 5.1: RST_STREAM can be received in any of these states
          // Close the stream and remove it
          _logger.debug("RST_STREAM closing active stream",
            LogFields(_connection_id).with_stream_id(frame.stream_id))
          _streams.close_stream(frame.stream_id)
          true
        end
      end
    else
      _on_error(conn, HTTP2Error.frame_size_error(),
        "Invalid RST_STREAM payload")
      return false
    end

  fun ref _handle_ping(conn: TCPConnection ref, frame: HTTP2Frame): Bool =>
    """
    Handle PING frame per RFC 7540 Section 6.7.
    """
    if frame.stream_id != 0 then
      _on_error(conn, HTTP2Error.protocol_error(),
        "PING with non-zero stream ID")
      return false
    end

    if frame.payload.size() != 8 then
      _on_error(conn, HTTP2Error.frame_size_error(),
        "Invalid PING payload size")
      return false
    end

    // If not an ACK, send response
    if not frame.is_ack() then
      let builder = HTTP2FrameBuilder
      conn.write(builder.build_ping(true, frame.payload))
    end

    true

  fun ref _handle_goaway(conn: TCPConnection ref, frame: HTTP2Frame): Bool =>
    """
    Handle GOAWAY frame per RFC 7540 Section 6.8.
    """
    if frame.stream_id != 0 then
      _on_error(conn, HTTP2Error.protocol_error(),
        "GOAWAY with non-zero stream ID")
      return false
    end

    if frame.payload.size() < 8 then
      _on_error(conn, HTTP2Error.frame_size_error(),
        "Invalid GOAWAY payload size")
      return false
    end

    try
      let last_stream_id = ((frame.payload(0)?.u32() << 24) or
                            (frame.payload(1)?.u32() << 16) or
                            (frame.payload(2)?.u32() << 8) or
                            frame.payload(3)?.u32()) and 0x7FFFFFFF

      let error_code = (frame.payload(4)?.u32() << 24) or
                       (frame.payload(5)?.u32() << 16) or
                       (frame.payload(6)?.u32() << 8) or
                       frame.payload(7)?.u32()

      _logger.info(
        "GOAWAY received: last_stream_id=" + last_stream_id.string() +
        " error_code=" + error_code.string(),
        LogFields(_connection_id)
      )

      _goaway_received = true

      // Close connection
      conn.dispose()
      return false
    else
      _on_error(conn, HTTP2Error.frame_size_error(),
        "Invalid GOAWAY payload")
      return false
    end

  fun ref _handle_priority(conn: TCPConnection ref, frame: HTTP2Frame): Bool =>
    """
    Handle PRIORITY frame per RFC 7540 Section 6.3.
    PRIORITY frames can be sent/received in any stream state.
    Per RFC 7540 Section 5.1: PRIORITY can be sent/received in idle state.

    RFC 7540 Section 6.3: "The PRIORITY frame can be sent for a stream in the
    "idle" state. This allows for the reprioritization of a group of dependent
    streams by altering the priority of an unused or closed parent stream."

    RFC 7540 Section 5.1: "A PRIORITY frame can be received in any state, though
    it can only be sent in the open or half-closed (remote) states."
    """
    if frame.stream_id == 0 then
      _on_error(conn, HTTP2Error.protocol_error(),
        "PRIORITY with stream ID 0")
      return false
    end

    if frame.payload.size() != 5 then
      _on_error(conn, HTTP2Error.frame_size_error(),
        "Invalid PRIORITY payload size")
      return false
    end

    // Parse priority information
    try
      let dep_and_flags = ((frame.payload(0)?.u32() << 24) or
                          (frame.payload(1)?.u32() << 16) or
                          (frame.payload(2)?.u32() << 8) or
                          frame.payload(3)?.u32())
      let dependency = dep_and_flags and 0x7FFFFFFF
      let exclusive = (dep_and_flags and 0x80000000) != 0
      let weight = frame.payload(4)?

      // Check for self-dependency (RFC 7540 Section 5.3.1)
      if dependency == frame.stream_id then
        // Per RFC 7540 Section 5.3.1: A stream cannot depend on itself
        _send_rst_stream(conn, frame.stream_id, HTTP2Error.protocol_error())
        return true
      end

      // Per RFC 7540 Section 5.1: PRIORITY can be sent on idle streams
      // When PRIORITY is sent on an idle stream, it doesn't create a stream.
    let stream_opt = _streams.get_stream(frame.stream_id)
    match stream_opt
    | None =>
      // Stream doesn't exist - idle state. Store priority info without
      // creating the stream or affecting concurrent stream limits.
      if _streams.is_closed(frame.stream_id) then
        // Stream was closed earlier; ignore PRIORITY per advisory semantics.
        _logger.debug("PRIORITY frame on closed stream ignored",
          LogFields(_connection_id).with_stream_id(frame.stream_id))
      else
        _streams.set_pending_priority(frame.stream_id, dependency, exclusive, weight)
        _logger.debug("PRIORITY frame stored for idle stream",
          LogFields(_connection_id).with_stream_id(frame.stream_id))
      end
      true
    | let stream: HTTP2Stream ref =>
      // Stream exists - ignore if already closed
      match stream.state
      | StreamStateClosed =>
        _logger.debug("PRIORITY frame on closed stream ignored",
          LogFields(_connection_id).with_stream_id(frame.stream_id))
        true
      else
        stream.set_priority(dependency, exclusive, weight)
        _logger.debug("PRIORITY frame processed for existing stream",
          LogFields(_connection_id).with_stream_id(frame.stream_id))
        true
      end
    end
    else
      _on_error(conn, HTTP2Error.frame_size_error(),
        "Invalid PRIORITY payload")
      false
    end

  // Request dispatch

  fun ref _dispatch_request(conn: TCPConnection ref, stream_id: U32): Bool =>
    """
    Dispatch a complete request to the router.
    """
    let stream_opt = _streams.get_or_create_stream(stream_id)
    match stream_opt
    | None =>
      _send_rst_stream(conn, stream_id, HTTP2Error.refused_stream())
      true
    | let stream: HTTP2Stream ref =>
      // Fallback: parse content-length from stored headers if needed
      match stream.expected_content_length
      | None =>
        if stream.headers.contains("content-length") then
          try
            let header_value = stream.headers("content-length")?
            let trimmed = _trim_ows(header_value)
            stream.expected_content_length = trimmed.usize()?
          else
            _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
            return true
          end
        end
      end
      match stream.expected_content_length
      | let expected: USize =>
        if stream.received_bytes != expected then
          _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
          return true
        end
      end
      // Validate required pseudo-headers
      if not stream.headers.contains(":method") then
        _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
        return true
      end

      if not stream.headers.contains(":path") then
        _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
        return true
      end

      // Create HTTP request
      let method = try
        stream.headers(":method")?
      else
        ""
      end

      let path = try
        stream.headers(":path")?
      else
        ""
      end

      let req = HTTPRequest.from_http2(
        method,
        path,
        stream.headers,
        stream.body,
        _max_body_size
      )

      // Route request
      let response = _router.route(req)

      _logger.info(
        "HTTP/2 request: method=" + method +
        " path=" + path +
        " status=" + response.status_code().string(),
        LogFields(_connection_id)
          .with_stream_id(stream_id)
          .with_method(method)
          .with_path(path)
          .with_status_code(response.status_code())
      )

      // Send response
      send_response(conn, stream_id, response)

      true
    end

  // Response sending

  fun ref send_response(
    conn: TCPConnection ref,
    stream_id: U32,
    response: HTTPResponse)
  =>
    """
    Send an HTTP/2 response.
    """
    let status = response.status_code()
    let body = response.get_body()
    let headers = response.get_headers()

    // Build response headers
    let resp_headers = Array[(String, String)]
    resp_headers.push((":status", status.string()))

    // Add response headers
    for (name, value) in headers.pairs() do
      // Skip HTTP/1.1 specific headers
      if (name != "Connection") and (name != "Keep-Alive") and
         (name != "Transfer-Encoding") and (name != "Content-Length") then
        resp_headers.push((name.lower(), value))
      end
    end

    // Send HEADERS frame
    let end_stream = body.size() == 0
    _send_headers(conn, stream_id, resp_headers, end_stream)

    // Send response body if present
    if body.size() > 0 then
      _send_data(conn, stream_id, body, true)
    end

  fun ref _send_headers(
    conn: TCPConnection ref,
    stream_id: U32,
    headers: Array[(String, String)] ref,
    end_stream: Bool)
  =>
    """
    Send a HEADERS frame.
    """
    // Clone headers to val for HPACK encoder
    let headers_val = _clone_headers_to_val(headers)

    // Encode headers using HPACK
    let encoded = _hpack_encoder.encode(headers_val)

    let builder = HTTP2FrameBuilder
    conn.write(builder.build_headers(stream_id, consume encoded, end_stream, true))

    // Update stream state for sent HEADERS
    let stream_opt = _streams.get_stream(stream_id)
    match stream_opt
    | let stream: HTTP2Stream ref =>
      if not StreamStateHandler.handle_headers_sent(stream, end_stream) then
        _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
      elseif stream.state is StreamStateClosed then
        _streams.close_stream(stream_id)
      end
    end

  fun _clone_headers_to_val(headers: Array[(String, String)] ref): Array[(String, String)] val
  =>
    """
    Clone a ref array of headers to a val array.
    This is needed because we can't access ref data inside recover.
    We build the val array by consuming each element individually.
    """
    // Create the result array as iso, then consume to val
    let result = recover iso Array[(String, String)] end

    // We need to use index-based iteration since we can't use .values()
    // inside a method that returns val
    var i: USize = 0
    while i < headers.size() do
      try
        let h = headers(i)?
        // Clone the tuple by reconstructing it
        result.push((h._1, h._2))
      end
      i = i + 1
    end

    consume result

  fun ref _send_data(
    conn: TCPConnection ref,
    stream_id: U32,
    data: String val,
    end_stream: Bool)
  =>
    """
    Send DATA frames, respecting frame size limits and flow control.
    """
    let stream_opt = _streams.get_stream(stream_id)
    match stream_opt
    | let stream: HTTP2Stream ref =>
      let bytes = _string_to_bytes(data)
      for b in bytes.values() do
        stream.outbound_buffer.push(b)
      end
      if end_stream then
        stream.outbound_end_stream = true
      end
      _flush_stream_data(conn, stream_id, stream)
    end

  fun _string_to_bytes(data: String val): Array[U8] val =>
    """
    Convert a String to a byte array for DATA frame sending.
    """
    let arr = recover iso Array[U8] end
    arr.reserve(data.size())
    for b in data.values() do
      arr.push(b)
    end
    consume val arr

  fun ref _flush_stream_data(
    conn: TCPConnection ref,
    stream_id: U32,
    stream: HTTP2Stream ref)
  =>
    """
    Flush any pending outbound DATA for a stream, respecting flow control.
    """
    let builder = HTTP2FrameBuilder
    let max_size = _remote_settings.max_frame_size.usize()

    while stream.outbound_offset < stream.outbound_buffer.size() do
      let available_conn = _send_connection_window
      let available_stream = stream.get_remote_window_raw()
      if (available_conn <= 0) or (available_stream <= 0) then
        return
      end

      var available = available_conn
      if available_stream < available then
        available = available_stream
      end
      if available <= 0 then
        return
      end

      let remaining = stream.outbound_buffer.size() - stream.outbound_offset
      var chunk_size = remaining
      if chunk_size > max_size then
        chunk_size = max_size
      end
      if chunk_size > available.usize() then
        chunk_size = available.usize()
      end
      if chunk_size == 0 then
        return
      end

      // Extract chunk data before the recover block
      // Extract buffer data and offset before creating chunk
      let buffer_size = stream.outbound_buffer.size()
      let offset = stream.outbound_offset

      // Create and populate the chunk array
      let chunk_iso = recover iso
        let arr = Array[U8](chunk_size)
        var i: USize = 0
        while i < chunk_size do
          if (offset + i) < buffer_size then
            // Placeholder - will be replaced below
            arr.push(0)
          end
          i = i + 1
        end
        consume arr
      end

      // Copy the actual data
      var i: USize = 0
      while i < chunk_size do
        if (offset + i) < buffer_size then
          try
            chunk_iso(i)? = stream.outbound_buffer(offset + i)?
          end
        end
        i = i + 1
      end

      let chunk: Array[U8] val = consume chunk_iso

      let is_last = (stream.outbound_offset + chunk_size) >= stream.outbound_buffer.size()
      let send_end_stream = stream.outbound_end_stream and is_last
      conn.write(builder.build_data(stream_id, consume chunk, send_end_stream))

      // Consume flow control windows
      _send_connection_window = _send_connection_window - chunk_size.i32()
      stream.consume_remote_window(chunk_size.u32())

      stream.outbound_offset = stream.outbound_offset + chunk_size

      if send_end_stream then
        if StreamStateHandler.handle_data_sent(stream, true) then
          if stream.state is StreamStateClosed then
            _streams.close_stream(stream_id)
          end
        else
          _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
        end
      end
    end

    if stream.outbound_offset >= stream.outbound_buffer.size() then
      stream.outbound_buffer.clear()
      stream.outbound_offset = 0
      if stream.outbound_end_stream then
        stream.outbound_end_stream = false
      end
    end

  fun ref _flush_pending_data(conn: TCPConnection ref) =>
    """
    Flush pending outbound DATA for all active streams.
    """
    let streams = _streams.get_active_streams()
    for (id, stream) in streams.values() do
      if stream.outbound_offset < stream.outbound_buffer.size() then
        _flush_stream_data(conn, id, stream)
      end
    end

  fun ref _send_connection_window_update(conn: TCPConnection ref, increment: U32) =>
    """
    Send connection-level WINDOW_UPDATE.
    """
    let builder = HTTP2FrameBuilder
    conn.write(builder.build_window_update(0, increment))

  // Error handling

  fun ref _send_goaway(
    conn: TCPConnection ref,
    last_stream_id: U32,
    error_code: U32,
    debug_data: String = "")
  =>
    """
    Send a GOAWAY frame and close the connection.
    Per RFC 7540 Section 6.8: After sending GOAWAY, the sender must not
    initiate any new streams and should close the connection.
    """
    _goaway_sent = true

    let builder = HTTP2FrameBuilder
    // Don't include debug data to avoid potential frame size issues
    conn.write(builder.build_goaway(last_stream_id, error_code, recover val Array[U8] end))

    _logger.warn(
      "GOAWAY sent: last_stream_id=" + last_stream_id.string() +
      " error_code=" + error_code.string() +
      " debug=" + debug_data,
      LogFields(_connection_id)
    )

    // Flush the write and close the connection
    conn.dispose()

  fun ref _send_rst_stream(conn: TCPConnection ref, stream_id: U32, error_code: U32) =>
    """
    Send an RST_STREAM frame.
    """
    let builder = HTTP2FrameBuilder
    conn.write(builder.build_rst_stream(stream_id, error_code))

    // Close the stream
    _streams.close_stream(stream_id)

  fun ref _on_error(
    conn: TCPConnection ref,
    error_code: U32,
    message: String)
  =>
    """
    Handle a connection error by sending GOAWAY.
    Per RFC 7540 Section 6.8: The last stream ID is the last stream
    that was or might be processed by the server.
    """
    _logger.log_error(
      "HTTP/2 error: " + message + " (code=" + error_code.string() + ")",
      LogFields(_connection_id)
    )

    // Use the stream manager's last processed stream ID if available,
    // otherwise fall back to our tracked last stream ID
    let goaway_stream_id = _streams.get_last_stream_id()
    if goaway_stream_id > _last_stream_id then
      _send_goaway(conn, goaway_stream_id, error_code, message)
    else
      _send_goaway(conn, _last_stream_id, error_code, message)
    end

  // Header validation per RFC 7540 Section 8.1.2

  fun ref _validate_headers(
    conn: TCPConnection ref,
    stream_id: U32,
    headers: Array[(String, String)])
    : Bool
  =>
    """
    Validate headers per RFC 7540 Section 8.1.2.
    Returns true if valid, false if invalid (and RST_STREAM was sent).
    """
    var seen_regular_header = false
    var seen_pseudo_headers: Set[String] = Set[String]
    var has_method = false
    var has_path = false
    var has_scheme = false

    for (name, value) in headers.values() do
      // Check 1: Header names must be lowercase (RFC 7540 Section 8.1.2)
      if not _is_lowercase_header(name) then
        _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
        return false
      end

      // Check 2: Connection-specific headers are prohibited (RFC 7540 Section 8.1.2.2)
      let lower_name = name.lower()
      if (lower_name == "connection") or
         (lower_name == "keep-alive") or
         (lower_name == "proxy-connection") or
         (lower_name == "transfer-encoding") or
         (lower_name == "upgrade") then
        _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
        return false
      end

      // Check 3: TE header field (RFC 7540 Section 8.1.2.2)
      // Only "trailers" is allowed, and it must be the only value
      if lower_name == "te" then
        let lower_value = value.lower()
        // TE must be exactly "trailers" (case-insensitive)
        // Any other value (including "trailers, deflate") is invalid
        if lower_value != "trailers" then
          _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
          return false
        end
      end

      // Check 4: Pseudo-headers validation
      if name.size() > 0 then
        try
          if name(0)? == ':' then
            // Pseudo-header found
            if seen_regular_header then
              // Pseudo-headers must appear before regular headers
              _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
              return false
            end

            // Check for duplicate pseudo-headers
            if seen_pseudo_headers.contains(name) then
              _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
              return false
            end
            seen_pseudo_headers.set(name)

            // Check valid pseudo-headers for requests
            // Valid: :method, :scheme, :authority, :path
            // Invalid in requests: :status
            if name == ":status" then
              // :status is a response pseudo-header, not valid in requests
              _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
              return false
            end

            if (name != ":method") and
               (name != ":scheme") and
               (name != ":authority") and
               (name != ":path") then
              // Unknown pseudo-header
              _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
              return false
            end

            // Check empty :path (RFC 7540 Section 8.1.2.3)
            if name == ":path" then
              if value.size() == 0 then
                // Empty :path is not allowed
                _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
                return false
              end
              has_path = true
            end

            // Track required pseudo-headers
            if name == ":method" then
              has_method = true
            end
            if name == ":scheme" then
              has_scheme = true
            end
          else
            // Regular header (not starting with ':')
            seen_regular_header = true
          end
        end
      end
    end

    // Check 5: All required pseudo-headers must be present (RFC 7540 Section 8.1.2.3)
    // :method, :scheme, and :path are mandatory for requests
    // Note: :authority is optional (can be empty for some methods like OPTIONS)
    if not (has_method and has_path and has_scheme) then
      _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
      return false
    end

    true

  fun ref _validate_trailers(
    conn: TCPConnection ref,
    stream_id: U32,
    headers: Array[(String, String)])
    : Bool
  =>
    """
    Validate trailers per RFC 7540 Section 8.1.2.
    Trailers must not include pseudo-headers.
    """
    for (name, value) in headers.values() do
      if not _is_lowercase_header(name) then
        _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
        return false
      end

      let lower_name = name.lower()
      if (lower_name == "connection") or
         (lower_name == "keep-alive") or
         (lower_name == "proxy-connection") or
         (lower_name == "transfer-encoding") or
         (lower_name == "upgrade") then
        _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
        return false
      end

      if lower_name == "te" then
        let lower_value = value.lower()
        if lower_value != "trailers" then
          _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
          return false
        end
      end

      if name.size() > 0 then
        try
          if name(0)? == ':' then
            _send_rst_stream(conn, stream_id, HTTP2Error.protocol_error())
            return false
          end
        end
      end
    end

    true

  fun _extract_content_length(
    headers: Array[(String, String)])
    : ((USize | None), Bool)
  =>
    """
    Extract content-length value from headers.
    Returns (value, error). If no content-length, value is None.
    """
    var seen = false
    var length: USize = 0

    for (name, value) in headers.values() do
      if name.lower() == "content-length" then
        let trimmed = _trim_ows(value)
        try
          let parsed = trimmed.usize()?
          if not seen then
            length = parsed
            seen = true
          else
            if parsed != length then
              return (None, true)
            end
          end
        else
          return (None, true)
        end
      end
    end

    if seen then
      (length, false)
    else
      (None, false)
    end

  fun _trim_ows(s: String): String =>
    """
    Trim optional whitespace (SP/HTAB) from both ends.
    """
    var start: USize = 0
    var end_idx: USize = s.size()

    while start < end_idx do
      try
        let c = s(start)?
        if (c == ' ') or (c == '\t') then
          start = start + 1
        else
          break
        end
      end
    end

    while end_idx > start do
      try
        let c = s(end_idx - 1)?
        if (c == ' ') or (c == '\t') then
          end_idx = end_idx - 1
        else
          break
        end
      end
    end

    s.substring(start.isize(), end_idx.isize())

  fun _is_lowercase_header(name: String): Bool =>
    """
    Check if a header name is all lowercase.
    Per RFC 7540 Section 8.1.2: Header field names MUST be lowercase.
    """
    for i in Range(0, name.size()) do
      try
        let c = name(i)?
        if (c >= 'A') and (c <= 'Z') then
          return false
        end
      end
    end
    true

  // Helper functions

  fun _get_header(
    headers: Array[(String, String)],
    name: String): String ?
  =>
    """
    Get a header value by name from the headers array.
    """
    for (n, v) in headers.values() do
      if n == name then
        return v
      end
    end
    error
