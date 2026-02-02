use "collections"

primitive StreamStateIdle
primitive StreamStateReservedLocal
primitive StreamStateReservedRemote
primitive StreamStateOpen
primitive StreamStateHalfClosedLocal
primitive StreamStateHalfClosedRemote
primitive StreamStateClosed

type StreamState is
  ( StreamStateIdle
  | StreamStateReservedLocal
  | StreamStateReservedRemote
  | StreamStateOpen
  | StreamStateHalfClosedLocal
  | StreamStateHalfClosedRemote
  | StreamStateClosed
  )

class HTTP2Stream
  """
  Represents a single HTTP/2 stream per RFC 7540 Section 5.

  Each stream has:
  - A unique 31-bit stream ID
  - A state machine (idle -> open -> half-closed -> closed)
  - Separate flow control windows for sending and receiving
  - Priority information (dependency, weight)
  - Buffer for partial headers (across CONTINUATION frames)

  Flow control:
  - Initial window size: 65535 bytes (RFC 7540 Section 6.5.2)
  - WINDOW_UPDATE frames adjust the window
  - Window cannot exceed 2^31-1 (RFC 7540 Section 6.5.2)
  """

  // Stream identification
  var stream_id: U32

  // State machine
  var state: StreamState

  // Flow control windows
  // Local window: how much data we can receive from peer
  // Remote window: how much data we can send to peer
  var _local_window: I32
  var _remote_window: I32

  // Priority information (RFC 7540 Section 5.3)
  var priority: U32  // Stream ID this stream depends on
  var exclusive: Bool  // Exclusive dependency flag
  var weight: U8  // Priority weight (1-256, default 16)

  // Headers buffer for partial headers across CONTINUATION frames
  var headers_buffer: Array[U8]
  // Pending END_STREAM flag for headers block spanning CONTINUATION frames
  var pending_end_stream: Bool
  // Outbound DATA buffering for flow control
  var outbound_buffer: Array[U8]
  var outbound_offset: USize
  var outbound_end_stream: Bool

  // END_STREAM tracking
  var received_end_stream: Bool
  var sent_end_stream: Bool

  // Request/Response data storage
  var body: Array[U8]
  var received_bytes: USize
  var end_headers_received: Bool
  var headers: Map[String, String]
  var received_initial_headers: Bool
  var received_trailers: Bool
  var expected_content_length: (USize | None)

  // Constants per RFC 7540
  let _default_window_size: I32 = 65535
  let _max_window_size: I32 = 0x7FFFFFFF  // 2^31 - 1

  new create(
    id: U32,
    local_window_size: U32 = 65535,
    remote_window_size: U32 = 65535)
  =>
    """
    Create a new HTTP/2 stream in the idle state.

    Parameters:
    - id: The 31-bit stream identifier
    """
    stream_id = id
    state = StreamStateIdle
    _local_window = local_window_size.i32()
    _remote_window = remote_window_size.i32()
    priority = 0
    exclusive = false
    weight = 16
    headers_buffer = Array[U8]
    pending_end_stream = false
    outbound_buffer = Array[U8]
    outbound_offset = 0
    outbound_end_stream = false
    received_end_stream = false
    sent_end_stream = false
    body = Array[U8]
    received_bytes = 0
    end_headers_received = false
    headers = Map[String, String]
    received_initial_headers = false
    received_trailers = false
    expected_content_length = None

  fun can_receive(): Bool =>
    """
    Check if the stream can receive data from the peer.
    Returns true if the stream is in a state that allows receiving.
    """
    match state
    | StreamStateOpen => true
    | StreamStateHalfClosedLocal => true
    | StreamStateReservedRemote => true
    else
      false
    end

  fun can_send(): Bool =>
    """
    Check if the stream can send data to the peer.
    Returns true if the stream is in a state that allows sending.
    """
    match state
    | StreamStateOpen => true
    | StreamStateHalfClosedRemote => true
    | StreamStateReservedLocal => true
    else
      false
    end

  fun is_open(): Bool =>
    """
    Check if the stream is in the Open state.
    """
    match state
    | StreamStateOpen => true
    else
      false
    end

  fun is_closed(): Bool =>
    """
    Check if the stream is in the Closed state.
    """
    match state
    | StreamStateClosed => true
    else
      false
    end

  fun ref update_local_window(delta: I32): Bool =>
    """
    Update the local flow control window (for receiving data).
    Called when we receive a WINDOW_UPDATE frame from the peer.

    Parameters:
    - delta: The increment value (must be positive)

    Returns:
    - true if the update was successful
    - false if the update would cause a flow control error
      (window exceeds 2^31-1)
    """
    // Check for overflow
    let new_window = _local_window.i64() + delta.i64()
    if (new_window < 0) or (new_window > _max_window_size.i64()) then
      return false
    end
    _local_window = new_window.i32()
    true

  fun ref update_remote_window(delta: I32): Bool =>
    """
    Update the remote flow control window (for sending data).
    Called when we send a WINDOW_UPDATE frame to the peer.

    Parameters:
    - delta: The increment value (must be positive)

    Returns:
    - true if the update was successful
    - false if the update would cause a flow control error
      (window exceeds 2^31-1)
    """
    // Check for overflow
    let new_window = _remote_window.i64() + delta.i64()
    if new_window > _max_window_size.i64() then
      return false
    end
    _remote_window = new_window.i32()
    true

  fun get_local_window(): U32 =>
    """
    Get the current local window size.
    Returns the number of bytes we can receive.
    """
    if _local_window < 0 then
      0
    else
      _local_window.u32()
    end

  fun get_remote_window(): U32 =>
    """
    Get the current remote window size.
    Returns the number of bytes we can send.
    """
    if _remote_window < 0 then
      0
    else
      _remote_window.u32()
    end

  fun get_remote_window_raw(): I32 =>
    """
    Get the raw remote window size (can be negative).
    """
    _remote_window

  fun ref consume_local_window(amount: U32): Bool =>
    """
    Consume bytes from the local window when receiving data.

    Parameters:
    - amount: Number of bytes received

    Returns:
    - true if the consumption was successful
    - false if it would cause a flow control violation
    """
    let new_window = _local_window.i64() - amount.i64()
    if new_window < 0 then
      return false
    end
    _local_window = new_window.i32()
    true

  fun ref consume_remote_window(amount: U32): Bool =>
    """
    Consume bytes from the remote window when sending data.

    Parameters:
    - amount: Number of bytes to send

    Returns:
    - true if the consumption was successful
    - false if it would cause a flow control violation
    """
    let new_window = _remote_window.i64() - amount.i64()
    if new_window < 0 then
      return false
    end
    _remote_window = new_window.i32()
    true

  fun ref adjust_remote_window_by(diff: I32): Bool =>
    """
    Adjust the remote flow control window by a delta.
    Used when SETTINGS_INITIAL_WINDOW_SIZE changes.

    Parameters:
    - diff: The delta to apply (can be negative)

    Returns:
    - true if successful
    - false if it would exceed the maximum window size
    """
    let new_window = _remote_window.i64() + diff.i64()
    if new_window > _max_window_size.i64() then
      return false
    end
    _remote_window = new_window.i32()
    true

  fun ref set_priority(dep_stream_id: U32, is_exclusive: Bool, stream_weight: U8) =>
    """
    Set the stream priority information.

    Parameters:
    - dep_stream_id: The stream ID this stream depends on
    - is_exclusive: Whether this is an exclusive dependency
    - stream_weight: The priority weight (1-256, stored as weight-1 in 8 bits)
    """
    priority = dep_stream_id
    exclusive = is_exclusive
    weight = stream_weight

  fun ref append_headers(data: Array[U8] val) =>
    """
    Append header block fragments to the headers buffer.
    Used when receiving HEADERS/CONTINUATION frames.

    Parameters:
    - data: The header block fragment to append
    """
    for b in data.values() do
      headers_buffer.push(b)
    end

  fun ref clear_headers() =>
    """
    Clear the headers buffer after processing.
    """
    headers_buffer.clear()

  fun ref set_received_end_stream() =>
    """
    Mark that END_STREAM flag was received.
    """
    received_end_stream = true

  fun ref set_sent_end_stream() =>
    """
    Mark that END_STREAM flag was sent.
    """
    sent_end_stream = true

  fun ref reset_flow_control(initial_size: U32 = 65535) =>
    """
    Reset flow control windows to initial size.
    Called when a stream is created or reset.

    Parameters:
    - initial_size: The initial window size (default 65535)
    """
    _local_window = initial_size.i32()
    _remote_window = initial_size.i32()


class HTTP2StreamManager
  """
  Manages all HTTP/2 streams for a connection.

  Per RFC 7540:
  - Tracks active streams in a map
  - Enforces max concurrent streams limit (from SETTINGS)
  - Tracks last processed stream ID for GOAWAY
  - Validates stream ID types (client=odd, server=even)
  - Ensures monotonic stream ID progression
  """

  // Map of stream ID to stream object
  var _streams: Map[U32, HTTP2Stream ref]

  // Maximum concurrent streams allowed (from SETTINGS_MAX_CONCURRENT_STREAMS)
  var max_concurrent_streams: U32

  // Last stream ID processed (for GOAWAY)
  var last_processed_stream_id: U32

  // Track highest stream ID seen (for monotonic check)
  var _highest_stream_id: U32

  // Track stream counts by initiator
  var _client_stream_count: USize
  var _server_stream_count: USize

  // Track active (non-idle, non-closed) stream count for concurrency limiting
  // Per RFC 7540 Section 5.1.2: active streams exclude idle and closed states
  var _active_stream_count: USize

  // Initial window sizes for new streams
  var _local_initial_window_size: U32
  var _remote_initial_window_size: U32

  // Track closed stream IDs (for RST_STREAM handling)
  // Per RFC 7540 Section 5.1: After RST_STREAM, the stream is in closed state
  // and receiving HEADERS/DATA/CONTINUATION on it should be a stream error
  var _closed_streams: Set[U32]
  // Pending priority info for idle streams (PRIORITY on idle does not create stream)
  var _pending_priorities: Map[U32, (U32, Bool, U8)]

  new create(max_concurrent: U32 = 100) =>
    """
    Create a new stream manager.

    Parameters:
    - max_concurrent: Maximum concurrent streams (default 100)
    """
    _streams = Map[U32, HTTP2Stream ref]
    max_concurrent_streams = max_concurrent
    last_processed_stream_id = 0
    _highest_stream_id = 0
    _client_stream_count = 0
    _server_stream_count = 0
    _active_stream_count = 0
    _local_initial_window_size = 65535
    _remote_initial_window_size = 65535
    _closed_streams = Set[U32]
    _pending_priorities = Map[U32, (U32, Bool, U8)]

  fun ref create_stream(id: U32): (HTTP2Stream ref | None) =>
    """
    Create a new stream if under the concurrent limit.

    Parameters:
    - id: The stream ID to create

    Returns:
    - The new HTTP2Stream if created successfully
    - None if the limit is exceeded or stream already exists
    """
    // Check if stream already exists
    if _streams.contains(id) then
      return None
    end

    // Check concurrent limit using active stream count
    // Per RFC 7540 Section 5.1.2: Active streams exclude idle and closed states
    // When a stream is first created (from idle), it counts toward the limit
    if _active_stream_count >= max_concurrent_streams.usize() then
      return None
    end

    // Update highest stream ID
    if id > _highest_stream_id then
      _highest_stream_id = id
    end

    // Update stream counts
    if is_valid_client_stream_id(id) then
      _client_stream_count = _client_stream_count + 1
    elseif is_valid_server_stream_id(id) then
      _server_stream_count = _server_stream_count + 1
    end

    // Create and store the stream
    let stream = HTTP2Stream(id, _local_initial_window_size, _remote_initial_window_size)
    _streams.update(id, stream)

    // Increment active stream count
    // A newly created stream starts in non-closed state (typically idle or open)
    _active_stream_count = _active_stream_count + 1

    // Apply any pending priority info set while idle
    try
      let info = _pending_priorities(id)?
      stream.set_priority(info._1, info._2, info._3)
      _pending_priorities.remove(id)?
    end
    stream

  fun ref get_stream(id: U32): (HTTP2Stream ref | None) =>
    """
    Get a stream by ID.

    Parameters:
    - id: The stream ID to look up

    Returns:
    - The HTTP2Stream if found
    - None if the stream doesn't exist
    """
    try
      _streams(id)?
    else
      None
    end

  fun ref get_or_create_stream(id: U32): (HTTP2Stream ref | None) =>
    """
    Get an existing stream or create a new one.
    Used when receiving frames that may reference new streams.

    Parameters:
    - id: The stream ID

    Returns:
    - The HTTP2Stream (existing or newly created)
    - None if stream cannot be created (limit exceeded or invalid ID)
    """
    // Stream 0 is connection-level, not a real stream
    if id == 0 then
      return None
    end

    // Check if stream already exists
    try
      return _streams(id)?
    end

    // Create new stream
    create_stream(id)

  fun ref set_pending_priority(
    id: U32,
    dep_stream_id: U32,
    is_exclusive: Bool,
    stream_weight: U8)
  =>
    """
    Store priority information for an idle stream without creating it.
    """
    if id == 0 then
      return
    end
    _pending_priorities.update(id, (dep_stream_id, is_exclusive, stream_weight))

  fun ref close_stream(id: U32) =>
    """
    Close and remove a stream.

    Parameters:
    - id: The stream ID to close
    """
    try
      let stream = _streams(id)?
      _streams.remove(id)?

      // Update counts
      if is_valid_client_stream_id(id) then
        if _client_stream_count > 0 then
          _client_stream_count = _client_stream_count - 1
        end
      elseif is_valid_server_stream_id(id) then
        if _server_stream_count > 0 then
          _server_stream_count = _server_stream_count - 1
        end
      end

      // Decrement active stream count
      // The stream is now closed, so it no longer counts toward the limit
      if _active_stream_count > 0 then
        _active_stream_count = _active_stream_count - 1
      end

      // Update last processed if this is higher
      if id > last_processed_stream_id then
        last_processed_stream_id = id
      end

      // Add to closed streams set
      _closed_streams.set(id)
    end

  fun ref mark_closed(id: U32) =>
    """
    Mark a stream ID as closed even if no active stream exists.

    Parameters:
    - id: The stream ID to mark as closed
    """
    if id > last_processed_stream_id then
      last_processed_stream_id = id
    end
    _closed_streams.set(id)

  fun is_active(id: U32): Bool =>
    """
    Check if a stream is currently active.

    Parameters:
    - id: The stream ID to check

    Returns:
    - true if the stream exists and is active
    """
    _streams.contains(id)

  fun is_closed(id: U32): Bool =>
    """
    Check if a stream has been closed (via RST_STREAM or normal close).

    Parameters:
    - id: The stream ID to check

    Returns:
    - true if the stream was closed
    """
    _closed_streams.contains(id)

  fun get_stream_count(): USize =>
    """
    Get the total number of streams in the map.
    """
    _streams.size()

  fun get_active_stream_count(): USize =>
    """
    Get the number of active streams (excluding closed streams).
    Per RFC 7540 Section 5.1.2: Active streams exclude idle and closed states.
    """
    _active_stream_count

  fun ref get_active_streams(): Array[(U32, HTTP2Stream ref)] =>
    """
    Get a snapshot of all active streams.
    """
    let arr = Array[(U32, HTTP2Stream ref)]
    for (id, stream) in _streams.pairs() do
      arr.push((id, stream))
    end
    arr

  fun get_client_stream_count(): USize =>
    """
    Get the number of client-initiated streams.
    """
    _client_stream_count

  fun get_server_stream_count(): USize =>
    """
    Get the number of server-initiated streams.
    """
    _server_stream_count

  fun get_last_stream_id(): U32 =>
    """
    Get the last processed stream ID (for GOAWAY).
    """
    last_processed_stream_id

  fun is_valid_client_stream_id(id: U32): Bool =>
    """
    Check if a stream ID is valid for client-initiated streams.
    Per RFC 7540 Section 5.1.1: Client-initiated streams have odd IDs.

    Parameters:
    - id: The stream ID to validate

    Returns:
    - true if the ID is odd and non-zero
    """
    (id != 0) and ((id and 1) == 1)

  fun is_valid_server_stream_id(id: U32): Bool =>
    """
    Check if a stream ID is valid for server-initiated streams.
    Per RFC 7540 Section 5.1.1: Server-initiated streams have even IDs.

    Parameters:
    - id: The stream ID to validate

    Returns:
    - true if the ID is even and non-zero
    """
    (id != 0) and ((id and 1) == 0)

  fun check_stream_id_monotonic(id: U32): Bool =>
    """
    Check if a stream ID follows monotonic progression.
    Per RFC 7540 Section 5.1.1: Stream IDs must increase monotonically.

    Parameters:
    - id: The stream ID to check

    Returns:
    - true if the ID is >= highest seen ID for that initiator type
    """
    // Stream 0 is special (connection-level)
    if id == 0 then
      return true
    end

    // For client streams (odd), check against highest odd
    if is_valid_client_stream_id(id) then
      // Find highest client stream ID
      var highest_client: U32 = 0
      for (sid, _) in _streams.pairs() do
        if is_valid_client_stream_id(sid) and (sid > highest_client) then
          highest_client = sid
        end
      end
      return id > highest_client
    end

    // For server streams (even), check against highest even
    if is_valid_server_stream_id(id) then
      var highest_server: U32 = 0
      for (sid, _) in _streams.pairs() do
        if is_valid_server_stream_id(sid) and (sid > highest_server) then
          highest_server = sid
        end
      end
      return id > highest_server
    end

    false

  fun ref update_max_concurrent_streams(new_limit: U32) =>
    """
    Update the maximum concurrent streams limit.
    Called when receiving SETTINGS_MAX_CONCURRENT_STREAMS.

    Parameters:
    - new_limit: The new maximum concurrent streams
    """
    max_concurrent_streams = new_limit

  fun ref update_local_initial_window_size(new_size: U32) =>
    """
    Update the initial local (receive) window size for new streams.
    """
    _local_initial_window_size = new_size

  fun ref update_remote_initial_window_size(new_size: U32) =>
    """
    Update the initial remote (send) window size for new streams.
    """
    _remote_initial_window_size = new_size

  fun ref update_last_processed_stream_id(id: U32) =>
    """
    Update the last processed stream ID.
    Used for GOAWAY frame generation.

    Parameters:
    - id: The stream ID to set as last processed
    """
    if id > last_processed_stream_id then
      last_processed_stream_id = id
    end

  fun ref adjust_initial_window_size(delta: I32): Bool =>
    """
    Adjust the remote window size for all active streams.
    Called when SETTINGS_INITIAL_WINDOW_SIZE changes (peer setting).

    Parameters:
    - delta: The delta to apply to each stream window

    Returns:
    - true if all streams updated successfully
    - false if any stream would exceed the maximum window size
    """
    for (id, stream) in _streams.pairs() do
      if not stream.adjust_remote_window_by(delta) then
        return false
      end
    end
    true


primitive StreamStateHandler
  """
  Handles stream state transitions per RFC 7540 Section 5.1.

  State transitions:
  - Idle -> Open: HEADERS frame sent/received (without END_STREAM)
  - Idle -> ReservedLocal: PUSH_PROMISE sent
  - Idle -> ReservedRemote: PUSH_PROMISE received
  - Open -> HalfClosedLocal: END_STREAM sent
  - Open -> HalfClosedRemote: END_STREAM received
  - Open -> Closed: END_STREAM sent and received, or RST_STREAM
  - ReservedLocal -> HalfClosedRemote: HEADERS received
  - ReservedRemote -> HalfClosedLocal: HEADERS sent
  - HalfClosedLocal -> Closed: END_STREAM received, or RST_STREAM
  - HalfClosedRemote -> Closed: END_STREAM sent, or RST_STREAM
  - Any -> Closed: RST_STREAM sent or received
  """

  fun handle_headers_received(
    stream: HTTP2Stream ref,
    end_stream: Bool)
    : Bool
  =>
    """
    Handle HEADERS frame received from peer.

    Parameters:
    - stream: The stream to update
    - end_stream: Whether the END_STREAM flag is set

    Returns:
    - true if the transition was valid
    """
    match stream.state
    | StreamStateIdle =>
      // Transition to Open or HalfClosedRemote
      if end_stream then
        stream.state = StreamStateHalfClosedRemote
        stream.set_received_end_stream()
      else
        stream.state = StreamStateOpen
      end
      true

    | StreamStateReservedRemote =>
      // Transition to HalfClosedLocal (server push response headers)
      stream.state = StreamStateHalfClosedLocal
      true

    | StreamStateOpen =>
      // Additional HEADERS (trailers) - state unchanged
      if end_stream then
        stream.state = StreamStateHalfClosedRemote
        stream.set_received_end_stream()
      end
      true

    | StreamStateHalfClosedLocal =>
      // Receiving trailers
      if end_stream then
        stream.state = StreamStateClosed
        stream.set_received_end_stream()
      end
      true

    else
      // Invalid state for HEADERS
      false
    end

  fun handle_headers_sent(
    stream: HTTP2Stream ref,
    end_stream: Bool)
    : Bool
  =>
    """
    Handle HEADERS frame sent to peer.

    Parameters:
    - stream: The stream to update
    - end_stream: Whether the END_STREAM flag is set

    Returns:
    - true if the transition was valid
    """
    match stream.state
    | StreamStateIdle =>
      // Client initiating request
      if end_stream then
        stream.state = StreamStateHalfClosedLocal
        stream.set_sent_end_stream()
      else
        stream.state = StreamStateOpen
      end
      true

    | StreamStateReservedLocal =>
      // Server sending push promise response
      stream.state = StreamStateHalfClosedRemote
      true

    | StreamStateOpen =>
      // Sending trailers
      if end_stream then
        stream.state = StreamStateHalfClosedLocal
        stream.set_sent_end_stream()
      end
      true

    | StreamStateHalfClosedRemote =>
      // Sending trailers
      if end_stream then
        stream.state = StreamStateClosed
        stream.set_sent_end_stream()
      end
      true

    else
      // Invalid state for sending HEADERS
      false
    end

  fun handle_data_received(
    stream: HTTP2Stream ref,
    end_stream: Bool)
    : Bool
  =>
    """
    Handle DATA frame received from peer.

    Parameters:
    - stream: The stream to update
    - end_stream: Whether the END_STREAM flag is set

    Returns:
    - true if the transition was valid
    """
    match stream.state
    | StreamStateOpen =>
      if end_stream then
        stream.state = StreamStateHalfClosedRemote
        stream.set_received_end_stream()
      end
      true

    | StreamStateHalfClosedLocal =>
      if end_stream then
        stream.state = StreamStateClosed
        stream.set_received_end_stream()
      end
      true

    else
      // Cannot receive DATA in other states
      false
    end

  fun handle_data_sent(
    stream: HTTP2Stream ref,
    end_stream: Bool)
    : Bool
  =>
    """
    Handle DATA frame sent to peer.

    Parameters:
    - stream: The stream to update
    - end_stream: Whether the END_STREAM flag is set

    Returns:
    - true if the transition was valid
    """
    match stream.state
    | StreamStateOpen =>
      if end_stream then
        stream.state = StreamStateHalfClosedLocal
        stream.set_sent_end_stream()
      end
      true

    | StreamStateHalfClosedRemote =>
      if end_stream then
        stream.state = StreamStateClosed
        stream.set_sent_end_stream()
      end
      true

    else
      // Cannot send DATA in other states
      false
    end

  fun handle_rst_stream_received(stream: HTTP2Stream ref): Bool =>
    """
    Handle RST_STREAM frame received from peer.
    Immediately closes the stream.

    Parameters:
    - stream: The stream to update

    Returns:
    - true if the transition was valid
    """
    match stream.state
    | StreamStateIdle =>
      // Per RFC 7540 Section 5.1: RST_STREAM can be received in idle state
      // to reject a stream. This transitions to closed state.
      stream.state = StreamStateClosed
      true

    | StreamStateClosed =>
      // Stream already closed
      true

    else
      stream.state = StreamStateClosed
      true
    end

  fun handle_rst_stream_sent(stream: HTTP2Stream ref): Bool =>
    """
    Handle RST_STREAM frame sent to peer.
    Immediately closes the stream.

    Parameters:
    - stream: The stream to update

    Returns:
    - true if the transition was valid
    """
    match stream.state
    | StreamStateIdle =>
      // Sending RST_STREAM on idle stream is allowed
      stream.state = StreamStateClosed
      true

    | StreamStateClosed =>
      // Stream already closed
      true

    else
      stream.state = StreamStateClosed
      true
    end

  fun handle_push_promise_received(stream: HTTP2Stream ref): Bool =>
    """
    Handle PUSH_PROMISE frame received from peer.
    Transitions from Idle to ReservedRemote.

    Parameters:
    - stream: The stream to update

    Returns:
    - true if the transition was valid
    """
    match stream.state
    | StreamStateIdle =>
      stream.state = StreamStateReservedRemote
      true

    else
      // PUSH_PROMISE only valid in Idle state
      false
    end

  fun handle_push_promise_sent(stream: HTTP2Stream ref): Bool =>
    """
    Handle PUSH_PROMISE frame sent to peer.
    Transitions from Idle to ReservedLocal.

    Parameters:
    - stream: The stream to update

    Returns:
    - true if the transition was valid
    """
    match stream.state
    | StreamStateIdle =>
      stream.state = StreamStateReservedLocal
      true

    | StreamStateOpen =>
      // Server can send PUSH_PROMISE on open client stream
      // This creates a new reserved stream
      true

    else
      // PUSH_PROMISE only valid in Idle or Open state
      false
    end

  fun handle_end_stream_received(stream: HTTP2Stream ref): Bool =>
    """
    Handle END_STREAM flag received (from HEADERS or DATA).

    Parameters:
    - stream: The stream to update

    Returns:
    - true if the transition was valid
    """
    match stream.state
    | StreamStateOpen =>
      stream.state = StreamStateHalfClosedRemote
      stream.set_received_end_stream()
      true

    | StreamStateHalfClosedLocal =>
      stream.state = StreamStateClosed
      stream.set_received_end_stream()
      true

    else
      false
    end

  fun handle_end_stream_sent(stream: HTTP2Stream ref): Bool =>
    """
    Handle END_STREAM flag sent (from HEADERS or DATA).

    Parameters:
    - stream: The stream to update

    Returns:
    - true if the transition was valid
    """
    match stream.state
    | StreamStateOpen =>
      stream.state = StreamStateHalfClosedLocal
      stream.set_sent_end_stream()
      true

    | StreamStateHalfClosedRemote =>
      stream.state = StreamStateClosed
      stream.set_sent_end_stream()
      true

    else
      false
    end


class FlowController
  """
  Manages HTTP/2 flow control per RFC 7540 Section 5.2.

  Flow control principles:
  - Both endpoints have independent flow control windows
  - Initial window size is 65535 bytes
  - WINDOW_UPDATE frames increase the window
  - Window cannot exceed 2^31-1
  - Flow control only applies to DATA frames
  """

  // Connection-level flow control window (for receiving)
  var _connection_window: I32

  // Default initial window size
  let _default_window: I32 = 65535

  // Maximum window size per RFC 7540
  let _max_window: I32 = 0x7FFFFFFF

  new create() =>
    """
    Create a new flow controller with default window size.
    """
    _connection_window = _default_window

  fun ref init_connection_window(size: U32) =>
    """
    Initialize the connection-level flow control window.

    Parameters:
    - size: The initial window size
    """
    _connection_window = size.i32()

  fun ref update_connection_window(delta: I32): Bool =>
    """
    Update the connection-level flow control window.

    Parameters:
    - delta: The increment value

    Returns:
    - true if successful
    - false if window would exceed 2^31-1
    """
    let new_window = _connection_window.i64() + delta.i64()
    if (new_window < 0) or (new_window > _max_window.i64()) then
      return false
    end
    _connection_window = new_window.i32()
    true

  fun ref consume_connection_window(amount: U32): Bool =>
    """
    Consume bytes from the connection window.

    Parameters:
    - amount: Number of bytes to consume

    Returns:
    - true if successful
    - false if insufficient window
    """
    let new_window = _connection_window.i64() - amount.i64()
    if new_window < 0 then
      return false
    end
    _connection_window = new_window.i32()
    true

  fun get_connection_window(): U32 =>
    """
    Get the current connection-level window size.
    """
    if _connection_window < 0 then
      0
    else
      _connection_window.u32()
    end

  fun is_window_valid(delta: I32): Bool =>
    """
    Check if a window update would be valid (not cause overflow).

    Parameters:
    - delta: The proposed increment

    Returns:
    - true if the update is valid
    """
    let new_window = _connection_window.i64() + delta.i64()
    (new_window >= 0) and (new_window <= _max_window.i64())
