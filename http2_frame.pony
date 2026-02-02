use "collections"
use @fprintf[I32](dest: Pointer[U8] tag, format: Pointer[U8] tag, ...)
use @pony_os_stderr[Pointer[U8]]()

primitive HTTP2FrameType
  """HTTP/2 frame type constants (RFC 7540 Section 6)"""
  fun data(): U8 => 0x0
  fun headers(): U8 => 0x1
  fun priority(): U8 => 0x2
  fun rst_stream(): U8 => 0x3
  fun settings(): U8 => 0x4
  fun push_promise(): U8 => 0x5
  fun ping(): U8 => 0x6
  fun goaway(): U8 => 0x7
  fun window_update(): U8 => 0x8
  fun continuation(): U8 => 0x9

primitive HTTP2FrameFlag
  """HTTP/2 frame flag constants (RFC 7540 Section 6)"""
  fun end_stream(): U8 => 0x1
  fun ack(): U8 => 0x1
  fun end_headers(): U8 => 0x4
  fun padded(): U8 => 0x8
  fun priority_flag(): U8 => 0x20

primitive HTTP2Error
  """HTTP/2 error codes (RFC 7540 Section 7)"""
  fun no_error(): U32 => 0x0
  fun protocol_error(): U32 => 0x1
  fun internal_error(): U32 => 0x2
  fun flow_control_error(): U32 => 0x3
  fun settings_timeout(): U32 => 0x4
  fun stream_closed(): U32 => 0x5
  fun frame_size_error(): U32 => 0x6
  fun refused_stream(): U32 => 0x7
  fun cancel(): U32 => 0x8
  fun compression_error(): U32 => 0x9
  fun connect_error(): U32 => 0xa
  fun enhance_your_calm(): U32 => 0xb
  fun inadequate_security(): U32 => 0xc
  fun http_1_1_required(): U32 => 0xd

primitive HTTP2FrameSize
  """HTTP/2 frame size constants (RFC 7540 Section 4.1)"""
  fun header_size(): USize => 9
  fun default_max_size(): USize => 16384
  fun absolute_max_size(): USize => 16777215

class val HTTP2Frame
  """
  Represents an HTTP/2 frame.
  Frame format (RFC 7540 Section 4.1):
  - Length: 3 bytes (payload length, max 2^24-1)
  - Type: 1 byte
  - Flags: 1 byte
  - Reserved: 1 bit
  - Stream Identifier: 31 bits
  - Payload: variable
  """
  let length: USize
  let frame_type: U8
  let flags: U8
  let stream_id: U32
  let payload: Array[U8] val

  new val create(
    length': USize,
    frame_type': U8,
    flags': U8,
    stream_id': U32,
    payload': Array[U8] val)
  =>
    length = length'
    frame_type = frame_type'
    flags = flags'
    stream_id = stream_id'
    payload = payload'

  fun is_end_stream(): Bool =>
    """Check if END_STREAM flag is set"""
    (flags and HTTP2FrameFlag.end_stream()) != 0

  fun is_end_headers(): Bool =>
    """Check if END_HEADERS flag is set"""
    (flags and HTTP2FrameFlag.end_headers()) != 0

  fun is_padded(): Bool =>
    """Check if PADDED flag is set"""
    (flags and HTTP2FrameFlag.padded()) != 0

  fun is_priority(): Bool =>
    """Check if PRIORITY flag is set"""
    (flags and HTTP2FrameFlag.priority_flag()) != 0

  fun is_ack(): Bool =>
    """Check if ACK flag is set"""
    (flags and HTTP2FrameFlag.ack()) != 0

  fun frame_type_name(): String =>
    """Get the human-readable name of the frame type"""
    match frame_type
    | HTTP2FrameType.data() => "DATA"
    | HTTP2FrameType.headers() => "HEADERS"
    | HTTP2FrameType.priority() => "PRIORITY"
    | HTTP2FrameType.rst_stream() => "RST_STREAM"
    | HTTP2FrameType.settings() => "SETTINGS"
    | HTTP2FrameType.ping() => "PING"
    | HTTP2FrameType.goaway() => "GOAWAY"
    | HTTP2FrameType.window_update() => "WINDOW_UPDATE"
    | HTTP2FrameType.continuation() => "CONTINUATION"
    else
      "UNKNOWN"
    end

  fun get_data_payload(): Array[U8] val =>
    """
    Get the actual data payload from a DATA frame, stripping padding if present.
    Per RFC 7540 Section 6.1:
    - If PADDED flag is set, first byte is pad length, last N bytes are padding
    - Returns the actual data between pad length byte and padding
    """
    if not is_padded() then
      return payload
    end

    // Padded frame: first byte is pad length
    if payload.size() < 1 then
      return recover val Array[U8] end
    end

    try
      let pad_length = payload(0)?.usize()
      // Data starts after pad length byte and ends before padding
      // Total: 1 (pad length) + data_length + pad_length = payload.size()
      // So data_length = payload.size() - 1 - pad_length
      let data_length = payload.size() - 1 - pad_length

      if data_length < 0 then
        // Invalid: pad length exceeds payload
        return recover val Array[U8] end
      end

      // Extract data portion (from index 1 to 1 + data_length)
      let result = recover iso Array[U8] end
      result.reserve(data_length)

      var i: USize = 1
      while i < (1 + data_length) do
        try
          result.push(payload(i)?)
        end
        i = i + 1
      end

      consume val result
    else
      recover val Array[U8] end
    end

  fun get_headers_payload(): Array[U8] val =>
    """
    Get the actual header block fragment from a HEADERS frame, stripping padding
    and priority fields if present.
    Per RFC 7540 Section 6.2:
    - If PADDED flag is set, first byte is pad length
    - If PRIORITY flag is set, next 5 bytes are priority info (after pad length)
    - Then comes the header block fragment
    - Finally comes the padding
    """
    var offset: USize = 0
    var pad_length: USize = 0

    // Check for PADDED flag
    if is_padded() then
      if payload.size() < 1 then
        return recover val Array[U8] end
      end
      try
        pad_length = payload(0)?.usize()
      else
        return recover val Array[U8] end
      end
      offset = 1
    end

    // Check for PRIORITY flag
    if is_priority() then
      // Priority fields: 4 bytes stream dependency + 1 byte weight = 5 bytes
      offset = offset + 5
    end

    // Calculate header block fragment length
    // Total: offset + header_block_length + pad_length = payload.size()
    let header_block_length = payload.size() - offset - pad_length

    if header_block_length < 0 then
      // Invalid: fields exceed payload
      return recover val Array[U8] end
    end

    // Extract header block fragment
    let result = recover iso Array[U8] end
    result.reserve(header_block_length)

    var i: USize = offset
    while i < (offset + header_block_length) do
      try
        result.push(payload(i)?)
      end
      i = i + 1
    end

    consume val result

  fun get_padding_length(): USize =>
    """Get the padding length from a padded frame. Returns 0 if not padded."""
    if not is_padded() then
      return 0
    end
    if payload.size() < 1 then
      return 0
    end
    try
      payload(0)?.usize()
    else
      0
    end

primitive FrameParseError
  """Error type for frame parsing failures"""

class HTTP2FrameParser
  """
  Parses HTTP/2 frames from a byte stream.
  """
  var _buffer: Array[U8]
  var _last_error: U32 = 0  // Last error code from validation failure
  var _max_frame_size: USize = HTTP2FrameSize.default_max_size()

  new create() =>
    _buffer = Array[U8]

  fun ref get_max_frame_size(): USize =>
    """Get the current maximum frame size setting."""
    _max_frame_size

  fun ref parse(data: Array[U8] val): (HTTP2Frame | None | FrameParseError) =>
    """
    Parse a frame from the provided data.
    Returns the frame if complete, None if more data is needed,
    or FrameParseError if the frame is invalid.
    """
    // Clear any previous error
    _last_error = 0

    // Append new data to buffer
    append_data(data)

    // Need at least the 9-byte header
    if _buffer.size() < HTTP2FrameSize.header_size() then
      return None
    end

    // Parse header fields
    let length = _parse_length()
    let frame_type = try _buffer(3)? else return None end
    let flags = try _buffer(4)? else return None end
    let stream_id = _parse_stream_id()

    let total_size = HTTP2FrameSize.header_size() + length

    // Check if we have the full frame
    if _buffer.size() < total_size then
      return None
    end

    // Debug: print all frames before validation
    @fprintf[I32](@pony_os_stderr[Pointer[U8]](),
      "FRAME PARSE: type=%d, length=%zu, stream_id=%u\n".cstring(),
      frame_type, length, stream_id)

    // Validate frame
    if not _validate_frame(length, frame_type, flags, stream_id) then
      // Invalid frame - this is a connection error per RFC 7540
      // We clear the buffer since the connection will be closed anyway
      _last_error = HTTP2Error.frame_size_error()
      // Debug: print frame details on validation failure
      @fprintf[I32](@pony_os_stderr[Pointer[U8]](),
        "FRAME VALIDATION FAILED: type=%d, length=%zu, stream_id=%u, max_frame_size=%zu\n".cstring(),
        frame_type, length, stream_id, _max_frame_size)
      _buffer.clear()
      return FrameParseError
    end

    // Extract payload - build iso array directly, then consume to val
    let payload_iso = recover iso
      let arr = Array[U8]
      arr.reserve(length)
      arr
    end

    // Fill the array outside of recover
    var i: USize = HTTP2FrameSize.header_size()
    while i < total_size do
      try
        payload_iso.push(_buffer(i)?)
      end
      i = i + 1
    end

    let payload = consume val payload_iso

    // Remove the frame from buffer
    _remove_frame(total_size)

    HTTP2Frame(length, frame_type, flags, stream_id, payload)

  fun ref get_last_error(): U32 =>
    """Get the last error code from validation failure"""
    _last_error

  fun ref _parse_length(): USize =>
    """Parse the 24-bit length field from the header"""
    try
      ((_buffer(0)?.usize() << 16) +
       (_buffer(1)?.usize() << 8) +
       _buffer(2)?.usize())
    else
      0
    end

  fun ref _parse_stream_id(): U32 =>
    """Parse the 31-bit stream ID from the header (ignoring reserved bit)"""
    try
      // Per RFC 7540 Section 4.1: The reserved bit (0x80) MUST be ignored
      ((_buffer(5)?.u32() << 24) +
       (_buffer(6)?.u32() << 16) +
       (_buffer(7)?.u32() << 8) +
       _buffer(8)?.u32()) and 0x7FFFFFFF
    else
      0
    end

  fun ref _parse_from_buffer(): (HTTP2Frame | None | FrameParseError) =>
    """
    Parse a frame from the internal buffer without appending new data.
    This is used internally by parse_next_frame().
    """
    // Need at least the 9-byte header
    if _buffer.size() < HTTP2FrameSize.header_size() then
      return None
    end

    // Parse header fields
    let length = _parse_length()
    let frame_type = try _buffer(3)? else return None end
    let flags = try _buffer(4)? else return None end
    let stream_id = _parse_stream_id()

    let total_size = HTTP2FrameSize.header_size() + length

    // Check if we have the full frame
    if _buffer.size() < total_size then
      return None
    end

    // Validate frame
    if not _validate_frame(length, frame_type, flags, stream_id) then
      _last_error = HTTP2Error.frame_size_error()
      _buffer.clear()
      return FrameParseError
    end

    // Extract payload
    let payload_iso = recover iso
      let arr = Array[U8]
      arr.reserve(length)
      arr
    end

    // Fill the array outside of recover
    var i: USize = HTTP2FrameSize.header_size()
    while i < total_size do
      try
        payload_iso.push(_buffer(i)?)
      end
      i = i + 1
    end

    let payload = consume val payload_iso

    // Remove the frame from buffer
    _remove_frame(total_size)

    HTTP2Frame(length, frame_type, flags, stream_id, payload)

  fun ref _validate_frame(length: USize, frame_type: U8, flags: U8, stream_id: U32): Bool =>
    """Validate frame according to HTTP/2 spec"""
    // Frame length must not exceed absolute maximum
    if length > HTTP2FrameSize.absolute_max_size() then
      return false
    end

    // Frame length must not exceed SETTINGS_MAX_FRAME_SIZE
    // Per RFC 7540 Section 4.2: An endpoint MUST send an error code of FRAME_SIZE_ERROR
    // if a peer sends a frame larger than the maximum size
    // Note: Unknown frame types are allowed and should be ignored per RFC 7540 Section 4.1
    // We only enforce frame size limits for known frame types
    // First check: frame size limits per frame type (RFC 7540 Section 4.2)
    match frame_type
    | HTTP2FrameType.data() =>
      if length > _max_frame_size then
        return false
      end
    | HTTP2FrameType.headers() =>
      if length > _max_frame_size then
        return false
      end
    | HTTP2FrameType.priority() =>
      if length != 5 then
        return false
      end
    | HTTP2FrameType.rst_stream() =>
      if length != 4 then
        return false
      end
    | HTTP2FrameType.settings() =>
      if (length % 6) != 0 then
        return false
      end
    | HTTP2FrameType.ping() =>
      if length != 8 then
        return false
      end
    | HTTP2FrameType.goaway() =>
      if length < 8 then
        return false
      end
    | HTTP2FrameType.window_update() =>
      if length != 4 then
        return false
      end
    | HTTP2FrameType.continuation() =>
      if length > _max_frame_size then
        return false
      end
    else
      // Unknown frame type - allowed but ignored per spec
      // Per RFC 7540 Section 4.1: An endpoint MUST ignore and discard any frame
      // that has a type that is unknown. We don't enforce frame size limits for
      // unknown frame types since we don't know their structure.
      return true
    end

    // Second check: frame type specific rules (stream ID, flags, etc.)
    match frame_type
    | HTTP2FrameType.data() =>
      // DATA frame: if padded, payload must be at least 1 byte (for pad length)
      let is_padded = (flags and HTTP2FrameFlag.padded()) != 0
      if is_padded and (length < 1) then
        return false
      end
      // DATA frame must not be on stream 0
      if stream_id == 0 then
        return false
      end
    | HTTP2FrameType.headers() =>
      // HEADERS frame: if padded, payload must be at least 1 byte (for pad length)
      let is_padded = (flags and HTTP2FrameFlag.padded()) != 0
      if is_padded and (length < 1) then
        return false
      end
      // HEADERS frame must not be on stream 0
      if stream_id == 0 then
        return false
      end
    | HTTP2FrameType.priority() =>
      // PRIORITY frame must not be on stream 0
      if stream_id == 0 then
        return false
      end
    | HTTP2FrameType.rst_stream() =>
      // RST_STREAM must not be on stream 0
      if stream_id == 0 then
        return false
      end
    | HTTP2FrameType.settings() =>
      // SETTINGS frame must be on stream 0
      if stream_id != 0 then
        return false
      end
    | HTTP2FrameType.ping() =>
      // PING frame must be on stream 0
      if stream_id != 0 then
        return false
      end
    | HTTP2FrameType.goaway() =>
      // GOAWAY must be on stream 0
      if stream_id != 0 then
        return false
      end
    | HTTP2FrameType.window_update() =>
      // WINDOW_UPDATE can be on any stream, including stream 0 (connection-level)
      // No additional checks needed
      None
    | HTTP2FrameType.continuation() =>
      // CONTINUATION frame must not be on stream 0
      if stream_id == 0 then
        return false
      end
    else
      // Unknown frame type - allowed but ignored per spec
      // Per RFC 7540 Section 4.1: An endpoint MUST ignore and discard any frame
      // that has a type that is unknown.
      return true
    end

    // If we reach here, all validation checks passed
    true

  fun ref _remove_frame(frame_size: USize) =>
    """Remove the parsed frame from the buffer"""
    if frame_size >= _buffer.size() then
      _buffer.clear()
    else
      // Create a new buffer with the remaining data
      let new_buffer = Array[U8]
      new_buffer.reserve(_buffer.size() - frame_size)

      // Copy remaining data to new buffer
      var i: USize = frame_size
      while i < _buffer.size() do
        try
          new_buffer.push(_buffer(i)?)
        end
        i = i + 1
      end

      _buffer = consume new_buffer
    end

  fun ref has_data(): Bool =>
    """Check if there's data in the buffer"""
    _buffer.size() > 0

  fun ref has_complete_frame(): Bool =>
    """
    Check if there's at least one complete frame in the buffer.
    A complete frame requires at least 9 bytes for the header,
    plus the payload length specified in the header.
    """
    // Need at least the 9-byte header
    if _buffer.size() < HTTP2FrameSize.header_size() then
      return false
    end

    // Parse the length field (first 3 bytes)
    let length = _parse_length()
    let total_size = HTTP2FrameSize.header_size() + length

    // Check if we have the full frame
    _buffer.size() >= total_size

  fun ref parse_next_frame(): (HTTP2Frame | None | FrameParseError) =>
    """
    Parse the next complete frame from the internal buffer.
    Assumes has_complete_frame() returned true.
    Returns the frame, None if no complete frame, or FrameParseError on validation failure.
    """
    // Parse directly from internal buffer without appending new data
    _parse_from_buffer()

  fun ref clear() =>
    """Clear the buffer"""
    _buffer.clear()

  fun ref buffer_size(): USize =>
    """Get the current buffer size"""
    _buffer.size()

  fun ref append_data(data: Array[U8] val) =>
    """Append data to the buffer"""
    for b in data.values() do
      _buffer.push(b)
    end

  fun ref set_max_frame_size(size: USize) =>
    """Set the maximum frame size for validation"""
    // Per RFC 7540 Section 4.2: SETTINGS_MAX_FRAME_SIZE must be between 2^14 and 2^24-1
    if (size >= 16384) and (size <= 16777215) then
      _max_frame_size = size
    end

class HTTP2FrameBuilder
  """
  Builds HTTP/2 frames.
  """

  fun build_settings(ack: Bool = false): Array[U8] val =>
    """Build a SETTINGS frame"""
    let flags: U8 = if ack then HTTP2FrameFlag.ack() else 0 end
    _build_frame(0, HTTP2FrameType.settings(), flags, 0, recover val Array[U8] end)

  fun build_settings_with_params(params: Array[(U16, U32)] val): Array[U8] val
  =>
    """Build a SETTINGS frame with parameters"""
    // Build payload in an iso array first
    let payload_iso = recover iso
      let arr = Array[U8]
      arr.reserve(params.size() * 6) // Each setting is 6 bytes

      for (id, value) in params.values() do
        arr.push((id >> 8).u8())
        arr.push(id.u8())
        arr.push((value >> 24).u8())
        arr.push((value >> 16).u8())
        arr.push((value >> 8).u8())
        arr.push(value.u8())
      end

      consume arr
    end

    let payload_size = payload_iso.size()
    let payload = consume val payload_iso
    _build_frame(payload_size, HTTP2FrameType.settings(), 0, 0, payload)

  fun _add_setting(payload: Array[U8], id: U16, value: U32) =>
    """Add a setting to the payload"""
    payload.push((id >> 8).u8())
    payload.push(id.u8())
    payload.push((value >> 24).u8())
    payload.push((value >> 16).u8())
    payload.push((value >> 8).u8())
    payload.push(value.u8())

  fun build_headers(
    stream_id: U32,
    header_block: Array[U8] val,
    end_stream: Bool = false,
    end_headers: Bool = true): Array[U8] val
  =>
    """Build a HEADERS frame"""
    var flags: U8 = 0
    if end_stream then
      flags = flags or HTTP2FrameFlag.end_stream()
    end
    if end_headers then
      flags = flags or HTTP2FrameFlag.end_headers()
    end
    _build_frame(header_block.size(), HTTP2FrameType.headers(), flags, stream_id, header_block)

  fun build_data(
    stream_id: U32,
    data: Array[U8] val,
    end_stream: Bool = false): Array[U8] val
  =>
    """Build a DATA frame"""
    let flags: U8 = if end_stream then HTTP2FrameFlag.end_stream() else 0 end
    _build_frame(data.size(), HTTP2FrameType.data(), flags, stream_id, data)

  fun build_rst_stream(stream_id: U32, error_code: U32): Array[U8] val =>
    """Build an RST_STREAM frame"""
    let payload = recover val
      [
        (error_code >> 24).u8()
        (error_code >> 16).u8()
        (error_code >> 8).u8()
        error_code.u8()
      ]
    end
    _build_frame(4, HTTP2FrameType.rst_stream(), 0, stream_id, payload)

  fun build_goaway(
    last_stream_id: U32,
    error_code: U32,
    debug_data: Array[U8] val = recover val Array[U8] end): Array[U8] val
  =>
    """Build a GOAWAY frame"""
    // Build payload in an iso array first
    let payload_iso = recover iso
      let arr = Array[U8]
      arr.reserve(8 + debug_data.size())
      arr
    end

    // Last stream ID (31 bits with reserved bit)
    payload_iso.push(((last_stream_id >> 24) and 0x7F).u8())
    payload_iso.push((last_stream_id >> 16).u8())
    payload_iso.push((last_stream_id >> 8).u8())
    payload_iso.push(last_stream_id.u8())

    // Error code
    payload_iso.push((error_code >> 24).u8())
    payload_iso.push((error_code >> 16).u8())
    payload_iso.push((error_code >> 8).u8())
    payload_iso.push(error_code.u8())

    // Debug data
    for b in debug_data.values() do
      payload_iso.push(b)
    end

    let payload_size = payload_iso.size()
    let payload = consume val payload_iso
    _build_frame(payload_size, HTTP2FrameType.goaway(), 0, 0, payload)

  fun build_window_update(stream_id: U32, increment: U32): Array[U8] val =>
    """Build a WINDOW_UPDATE frame"""
    // Increment must be 31 bits
    let inc = increment and 0x7FFFFFFF
    let payload = recover val
      [
        (inc >> 24).u8()
        (inc >> 16).u8()
        (inc >> 8).u8()
        inc.u8()
      ]
    end
    _build_frame(4, HTTP2FrameType.window_update(), 0, stream_id, payload)

  fun build_ping(ack: Bool = false, ping_payload: Array[U8] val = recover val [U8(0); U8(0); U8(0); U8(0); U8(0); U8(0); U8(0); U8(0)] end): Array[U8] val =>
    """Build a PING frame with optional payload"""
    let flags: U8 = if ack then HTTP2FrameFlag.ack() else 0 end
    // PING payload must be exactly 8 bytes
    let final_payload = if ping_payload.size() == 8 then
      ping_payload
    else
      recover val [U8(0); U8(0); U8(0); U8(0); U8(0); U8(0); U8(0); U8(0)] end
    end
    _build_frame(8, HTTP2FrameType.ping(), flags, 0, final_payload)

  fun build_priority(
    stream_id: U32,
    dependency: U32,
    weight: U8,
    exclusive: Bool = false): Array[U8] val
  =>
    """Build a PRIORITY frame"""
    let dep = if exclusive then
      dependency or 0x80000000
    else
      dependency
    end

    let payload = recover val
      [
        (dep >> 24).u8()
        (dep >> 16).u8()
        (dep >> 8).u8()
        dep.u8()
        weight
      ]
    end
    _build_frame(5, HTTP2FrameType.priority(), 0, stream_id, payload)

  fun build_continuation(
    stream_id: U32,
    header_block: Array[U8] val,
    end_headers: Bool = true): Array[U8] val
  =>
    """Build a CONTINUATION frame"""
    let flags: U8 = if end_headers then HTTP2FrameFlag.end_headers() else 0 end
    _build_frame(header_block.size(), HTTP2FrameType.continuation(), flags, stream_id, header_block)

  fun build_headers_with_padding(
    stream_id: U32,
    header_block: Array[U8] val,
    padding_length: U8,
    end_stream: Bool = false,
    end_headers: Bool = true): Array[U8] val
  =>
    """Build a HEADERS frame with padding"""
    var flags: U8 = HTTP2FrameFlag.padded()
    if end_stream then
      flags = flags or HTTP2FrameFlag.end_stream()
    end
    if end_headers then
      flags = flags or HTTP2FrameFlag.end_headers()
    end

    // Build payload in an iso array first
    let payload_iso = recover iso
      let arr = Array[U8]
      arr.reserve(1 + header_block.size() + padding_length.usize())
      arr
    end

    // Pad length
    payload_iso.push(padding_length)

    // Header block
    for b in header_block.values() do
      payload_iso.push(b)
    end

    // Padding
    for i in Range[U8](0, padding_length) do
      payload_iso.push(0)
    end

    let payload_size = payload_iso.size()
    let payload = consume val payload_iso
    _build_frame(payload_size, HTTP2FrameType.headers(), flags, stream_id, payload)

  fun build_data_with_padding(
    stream_id: U32,
    data: Array[U8] val,
    padding_length: U8,
    end_stream: Bool = false): Array[U8] val
  =>
    """Build a DATA frame with padding"""
    var flags: U8 = HTTP2FrameFlag.padded()
    if end_stream then
      flags = flags or HTTP2FrameFlag.end_stream()
    end

    // Build payload in an iso array first
    let payload_iso = recover iso
      let arr = Array[U8]
      arr.reserve(1 + data.size() + padding_length.usize())
      arr
    end

    // Pad length
    payload_iso.push(padding_length)

    // Data
    for b in data.values() do
      payload_iso.push(b)
    end

    // Padding
    for i in Range[U8](0, padding_length) do
      payload_iso.push(0)
    end

    let payload_size = payload_iso.size()
    let payload = consume val payload_iso
    _build_frame(payload_size, HTTP2FrameType.data(), flags, stream_id, payload)

  fun _build_frame(
    length: USize,
    frame_type: U8,
    flags: U8,
    stream_id: U32,
    payload: Array[U8] val): Array[U8] val
  =>
    """
    Build a complete frame from components.
    Frame format:
    - Length: 3 bytes
    - Type: 1 byte
    - Flags: 1 byte
    - Reserved: 1 bit (0)
    - Stream ID: 31 bits
    - Payload: variable
    """
    // Build frame in an iso array first
    let frame_iso = recover iso
      let arr = Array[U8]
      arr.reserve(HTTP2FrameSize.header_size() + length)
      arr
    end

    // Length (24 bits)
    let len = length and 0xFFFFFF
    frame_iso.push((len >> 16).u8())
    frame_iso.push((len >> 8).u8())
    frame_iso.push(len.u8())

    // Type (8 bits)
    frame_iso.push(frame_type)

    // Flags (8 bits)
    frame_iso.push(flags)

    // Reserved bit (0) + Stream ID (31 bits)
    let sid = stream_id and 0x7FFFFFFF
    frame_iso.push((sid >> 24).u8())
    frame_iso.push((sid >> 16).u8())
    frame_iso.push((sid >> 8).u8())
    frame_iso.push(sid.u8())

    // Payload
    for b in payload.values() do
      frame_iso.push(b)
    end

    consume val frame_iso
