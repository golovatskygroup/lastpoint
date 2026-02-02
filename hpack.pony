use "collections"

// HPACK Huffman decoding table entry
// Each entry contains: (code_bits, code_length, symbol, is_eos)
// Codes are stored in MSB-aligned format for efficient decoding
class _HuffmanEntry
  var code: U32
  var length: U8
  var symbol: U8
  var is_eos: Bool

  new create(code': U32, length': U8, symbol': U8, is_eos': Bool = false) =>
    code = code'
    length = length'
    symbol = symbol'
    is_eos = is_eos'

// HPACK Huffman decoder per RFC 7541 Appendix B
primitive _HuffmanDecoder
  """
  Huffman decoder for HPACK string literals.
  Uses the canonical Huffman code from RFC 7541 Appendix B.
  """

  // Huffman code table - entries for symbols 0-255 plus EOS (256)
  // Format: (code_bits_msb_aligned, bit_length, symbol)
  // Based on RFC 7541 Appendix B
  fun _huffman_table(): Array[_HuffmanEntry] val =>
    recover
      let table = Array[_HuffmanEntry](257)
      // Symbols 0-31 (control characters)
      table.push(_HuffmanEntry(0x1ff8, 13, 0))
      table.push(_HuffmanEntry(0x7fffd8, 23, 1))
      table.push(_HuffmanEntry(0xfffffe2, 28, 2))
      table.push(_HuffmanEntry(0xfffffe3, 28, 3))
      table.push(_HuffmanEntry(0xfffffe4, 28, 4))
      table.push(_HuffmanEntry(0xfffffe5, 28, 5))
      table.push(_HuffmanEntry(0xfffffe6, 28, 6))
      table.push(_HuffmanEntry(0xfffffe7, 28, 7))
      table.push(_HuffmanEntry(0xfffffe8, 28, 8))
      table.push(_HuffmanEntry(0xffffea, 24, 9))
      table.push(_HuffmanEntry(0x3ffffffc, 30, 10))
      table.push(_HuffmanEntry(0xfffffe9, 28, 11))
      table.push(_HuffmanEntry(0xfffffea, 28, 12))
      table.push(_HuffmanEntry(0x3ffffffd, 30, 13))
      table.push(_HuffmanEntry(0xfffffeb, 28, 14))
      table.push(_HuffmanEntry(0xfffffec, 28, 15))
      table.push(_HuffmanEntry(0xfffffed, 28, 16))
      table.push(_HuffmanEntry(0xfffffee, 28, 17))
      table.push(_HuffmanEntry(0xfffffef, 28, 18))
      table.push(_HuffmanEntry(0xffffff0, 28, 19))
      table.push(_HuffmanEntry(0xffffff1, 28, 20))
      table.push(_HuffmanEntry(0xffffff2, 28, 21))
      table.push(_HuffmanEntry(0x3ffffffe, 30, 22))
      table.push(_HuffmanEntry(0xffffff3, 28, 23))
      table.push(_HuffmanEntry(0xffffff4, 28, 24))
      table.push(_HuffmanEntry(0xffffff5, 28, 25))
      table.push(_HuffmanEntry(0xffffff6, 28, 26))
      table.push(_HuffmanEntry(0xffffff7, 28, 27))
      table.push(_HuffmanEntry(0xffffff8, 28, 28))
      table.push(_HuffmanEntry(0xffffff9, 28, 29))
      table.push(_HuffmanEntry(0xffffffa, 28, 30))
      table.push(_HuffmanEntry(0xffffffb, 28, 31))
      // Symbol 32 (space)
      table.push(_HuffmanEntry(0x14, 6, 32))
      // Symbols 33-47 (! through /)
      table.push(_HuffmanEntry(0x3f8, 10, 33))
      table.push(_HuffmanEntry(0x3f9, 10, 34))
      table.push(_HuffmanEntry(0xffa, 12, 35))
      table.push(_HuffmanEntry(0x1ff9, 13, 36))
      table.push(_HuffmanEntry(0x15, 6, 37))
      table.push(_HuffmanEntry(0xf8, 8, 38))
      table.push(_HuffmanEntry(0x7fa, 11, 39))
      table.push(_HuffmanEntry(0x3fa, 10, 40))
      table.push(_HuffmanEntry(0x3fb, 10, 41))
      table.push(_HuffmanEntry(0xf9, 8, 42))
      table.push(_HuffmanEntry(0x7fb, 11, 43))
      table.push(_HuffmanEntry(0xfa, 8, 44))
      table.push(_HuffmanEntry(0x16, 6, 45))
      table.push(_HuffmanEntry(0x17, 6, 46))
      table.push(_HuffmanEntry(0x18, 6, 47))
      // Symbols 48-57 (0-9)
      table.push(_HuffmanEntry(0x0, 5, 48))
      table.push(_HuffmanEntry(0x1, 5, 49))
      table.push(_HuffmanEntry(0x2, 5, 50))
      table.push(_HuffmanEntry(0x19, 6, 51))
      table.push(_HuffmanEntry(0x1a, 6, 52))
      table.push(_HuffmanEntry(0x1b, 6, 53))
      table.push(_HuffmanEntry(0x1c, 6, 54))
      table.push(_HuffmanEntry(0x1d, 6, 55))
      table.push(_HuffmanEntry(0x1e, 6, 56))
      table.push(_HuffmanEntry(0x1f, 6, 57))
      // Symbols 58-64 (: through @)
      table.push(_HuffmanEntry(0x5c, 7, 58))
      table.push(_HuffmanEntry(0xfb, 8, 59))
      table.push(_HuffmanEntry(0x7ffc, 15, 60))
      table.push(_HuffmanEntry(0x20, 6, 61))
      table.push(_HuffmanEntry(0xffb, 12, 62))
      table.push(_HuffmanEntry(0x3fc, 10, 63))
      table.push(_HuffmanEntry(0x1ffa, 13, 64))
      // Symbols 65-90 (A-Z)
      table.push(_HuffmanEntry(0x21, 6, 65))
      table.push(_HuffmanEntry(0x5d, 7, 66))
      table.push(_HuffmanEntry(0x5e, 7, 67))
      table.push(_HuffmanEntry(0x5f, 7, 68))
      table.push(_HuffmanEntry(0x60, 7, 69))
      table.push(_HuffmanEntry(0x61, 7, 70))
      table.push(_HuffmanEntry(0x62, 7, 71))
      table.push(_HuffmanEntry(0x63, 7, 72))
      table.push(_HuffmanEntry(0x64, 7, 73))
      table.push(_HuffmanEntry(0x65, 7, 74))
      table.push(_HuffmanEntry(0x66, 7, 75))
      table.push(_HuffmanEntry(0x67, 7, 76))
      table.push(_HuffmanEntry(0x68, 7, 77))
      table.push(_HuffmanEntry(0x69, 7, 78))
      table.push(_HuffmanEntry(0x6a, 7, 79))
      table.push(_HuffmanEntry(0x6b, 7, 80))
      table.push(_HuffmanEntry(0x6c, 7, 81))
      table.push(_HuffmanEntry(0x6d, 7, 82))
      table.push(_HuffmanEntry(0x6e, 7, 83))
      table.push(_HuffmanEntry(0x6f, 7, 84))
      table.push(_HuffmanEntry(0x70, 7, 85))
      table.push(_HuffmanEntry(0x71, 7, 86))
      table.push(_HuffmanEntry(0x72, 7, 87))
      table.push(_HuffmanEntry(0xfc, 8, 88))
      table.push(_HuffmanEntry(0x73, 7, 89))
      table.push(_HuffmanEntry(0xfd, 8, 90))
      // Symbols 91-96 ([ through `)
      table.push(_HuffmanEntry(0x1ffb, 13, 91))
      table.push(_HuffmanEntry(0x7fff0, 19, 92))
      table.push(_HuffmanEntry(0x1ffc, 13, 93))
      table.push(_HuffmanEntry(0x3ffc, 14, 94))
      table.push(_HuffmanEntry(0x22, 6, 95))
      table.push(_HuffmanEntry(0x7ffd, 15, 96))
      // Symbols 97-122 (a-z)
      table.push(_HuffmanEntry(0x3, 5, 97))
      table.push(_HuffmanEntry(0x23, 6, 98))
      table.push(_HuffmanEntry(0x4, 5, 99))
      table.push(_HuffmanEntry(0x24, 6, 100))
      table.push(_HuffmanEntry(0x5, 5, 101))
      table.push(_HuffmanEntry(0x25, 6, 102))
      table.push(_HuffmanEntry(0x26, 6, 103))
      table.push(_HuffmanEntry(0x27, 6, 104))
      table.push(_HuffmanEntry(0x6, 5, 105))
      table.push(_HuffmanEntry(0x74, 7, 106))
      table.push(_HuffmanEntry(0x75, 7, 107))
      table.push(_HuffmanEntry(0x28, 6, 108))
      table.push(_HuffmanEntry(0x29, 6, 109))
      table.push(_HuffmanEntry(0x2a, 6, 110))
      table.push(_HuffmanEntry(0x7, 5, 111))
      table.push(_HuffmanEntry(0x2b, 6, 112))
      table.push(_HuffmanEntry(0x76, 7, 113))
      table.push(_HuffmanEntry(0x2c, 6, 114))
      table.push(_HuffmanEntry(0x8, 5, 115))
      table.push(_HuffmanEntry(0x9, 5, 116))
      table.push(_HuffmanEntry(0x2d, 6, 117))
      table.push(_HuffmanEntry(0x77, 7, 118))
      table.push(_HuffmanEntry(0x78, 7, 119))
      table.push(_HuffmanEntry(0x79, 7, 120))
      table.push(_HuffmanEntry(0x7a, 7, 121))
      table.push(_HuffmanEntry(0x7b, 7, 122))
      // Symbols 123-126 ({ through ~)
      table.push(_HuffmanEntry(0x7ffe, 15, 123))
      table.push(_HuffmanEntry(0x7fc, 11, 124))
      table.push(_HuffmanEntry(0x3ffd, 14, 125))
      table.push(_HuffmanEntry(0x1ffd, 13, 126))
      // Symbol 127 (DEL)
      table.push(_HuffmanEntry(0xffffffc, 28, 127))
      // Symbols 128-255 (extended ASCII)
      table.push(_HuffmanEntry(0xfffe6, 20, 128))
      table.push(_HuffmanEntry(0x3fffd2, 22, 129))
      table.push(_HuffmanEntry(0xfffe7, 20, 130))
      table.push(_HuffmanEntry(0xfffe8, 20, 131))
      table.push(_HuffmanEntry(0x3fffd3, 22, 132))
      table.push(_HuffmanEntry(0x3fffd4, 22, 133))
      table.push(_HuffmanEntry(0x3fffd5, 22, 134))
      table.push(_HuffmanEntry(0x7fffd9, 23, 135))
      table.push(_HuffmanEntry(0x3fffd6, 22, 136))
      table.push(_HuffmanEntry(0x7fffda, 23, 137))
      table.push(_HuffmanEntry(0x7fffdb, 23, 138))
      table.push(_HuffmanEntry(0x7fffdc, 23, 139))
      table.push(_HuffmanEntry(0x7fffdd, 23, 140))
      table.push(_HuffmanEntry(0x7fffde, 23, 141))
      table.push(_HuffmanEntry(0xffffeb, 24, 142))
      table.push(_HuffmanEntry(0x7fffdf, 23, 143))
      table.push(_HuffmanEntry(0xffffec, 24, 144))
      table.push(_HuffmanEntry(0xffffed, 24, 145))
      table.push(_HuffmanEntry(0x3fffd7, 22, 146))
      table.push(_HuffmanEntry(0x7fffe0, 23, 147))
      table.push(_HuffmanEntry(0xffffee, 24, 148))
      table.push(_HuffmanEntry(0x7fffe1, 23, 149))
      table.push(_HuffmanEntry(0x7fffe2, 23, 150))
      table.push(_HuffmanEntry(0x7fffe3, 23, 151))
      table.push(_HuffmanEntry(0x7fffe4, 23, 152))
      table.push(_HuffmanEntry(0x1fffdc, 21, 153))
      table.push(_HuffmanEntry(0x3fffd8, 22, 154))
      table.push(_HuffmanEntry(0x7fffe5, 23, 155))
      table.push(_HuffmanEntry(0x3fffd9, 22, 156))
      table.push(_HuffmanEntry(0x7fffe6, 23, 157))
      table.push(_HuffmanEntry(0x7fffe7, 23, 158))
      table.push(_HuffmanEntry(0xffffef, 24, 159))
      table.push(_HuffmanEntry(0x3fffda, 22, 160))
      table.push(_HuffmanEntry(0x1fffdd, 21, 161))
      table.push(_HuffmanEntry(0xfffe9, 20, 162))
      table.push(_HuffmanEntry(0x3fffdb, 22, 163))
      table.push(_HuffmanEntry(0x3fffdc, 22, 164))
      table.push(_HuffmanEntry(0x7fffe8, 23, 165))
      table.push(_HuffmanEntry(0x7fffe9, 23, 166))
      table.push(_HuffmanEntry(0x1fffde, 21, 167))
      table.push(_HuffmanEntry(0x7fffea, 23, 168))
      table.push(_HuffmanEntry(0x3fffdd, 22, 169))
      table.push(_HuffmanEntry(0x3fffde, 22, 170))
      table.push(_HuffmanEntry(0xfffff0, 24, 171))
      table.push(_HuffmanEntry(0x1fffdf, 21, 172))
      table.push(_HuffmanEntry(0x3fffdf, 22, 173))
      table.push(_HuffmanEntry(0x7fffeb, 23, 174))
      table.push(_HuffmanEntry(0x7fffec, 23, 175))
      table.push(_HuffmanEntry(0x1fffe0, 21, 176))
      table.push(_HuffmanEntry(0x1fffe1, 21, 177))
      table.push(_HuffmanEntry(0x3fffe0, 22, 178))
      table.push(_HuffmanEntry(0x1fffe2, 21, 179))
      table.push(_HuffmanEntry(0x7fffed, 23, 180))
      table.push(_HuffmanEntry(0x3fffe1, 22, 181))
      table.push(_HuffmanEntry(0x7fffee, 23, 182))
      table.push(_HuffmanEntry(0x7fffef, 23, 183))
      table.push(_HuffmanEntry(0xfffeA, 20, 184))
      table.push(_HuffmanEntry(0x3fffe2, 22, 185))
      table.push(_HuffmanEntry(0x3fffe3, 22, 186))
      table.push(_HuffmanEntry(0x3fffe4, 22, 187))
      table.push(_HuffmanEntry(0x7ffff0, 23, 188))
      table.push(_HuffmanEntry(0x3fffe5, 22, 189))
      table.push(_HuffmanEntry(0x3fffe6, 22, 190))
      table.push(_HuffmanEntry(0x7ffff1, 23, 191))
      table.push(_HuffmanEntry(0x3fffffe0, 26, 192))
      table.push(_HuffmanEntry(0x3fffffe1, 26, 193))
      table.push(_HuffmanEntry(0xfffeB, 20, 194))
      table.push(_HuffmanEntry(0x3fffe7, 22, 195))
      table.push(_HuffmanEntry(0x3fffffe2, 26, 196))
      table.push(_HuffmanEntry(0x3fffffe3, 26, 197))
      table.push(_HuffmanEntry(0x3fffffe4, 26, 198))
      table.push(_HuffmanEntry(0x7fffffe0, 27, 199))
      table.push(_HuffmanEntry(0x3fffffe5, 26, 200))
      table.push(_HuffmanEntry(0x3fffffe6, 26, 201))
      table.push(_HuffmanEntry(0x7fffffe1, 27, 202))
      table.push(_HuffmanEntry(0x3fffffe7, 26, 203))
      table.push(_HuffmanEntry(0x7fffffe2, 27, 204))
      table.push(_HuffmanEntry(0xfffff1, 24, 205))
      table.push(_HuffmanEntry(0x1fffe3, 21, 206))
      table.push(_HuffmanEntry(0x3fffffe8, 26, 207))
      table.push(_HuffmanEntry(0x3fffffe9, 26, 208))
      table.push(_HuffmanEntry(0xffffffd, 28, 209))
      table.push(_HuffmanEntry(0x3fffffeA, 26, 210))
      table.push(_HuffmanEntry(0x7fffffe3, 27, 211))
      table.push(_HuffmanEntry(0x3fffffeB, 26, 212))
      table.push(_HuffmanEntry(0x7fffffe4, 27, 213))
      table.push(_HuffmanEntry(0x7fffffe5, 27, 214))
      table.push(_HuffmanEntry(0x7fffffe6, 27, 215))
      table.push(_HuffmanEntry(0x7fffffe7, 27, 216))
      table.push(_HuffmanEntry(0x7fffffe8, 27, 217))
      table.push(_HuffmanEntry(0x7fffffe9, 27, 218))
      table.push(_HuffmanEntry(0x7fffffea, 27, 219))
      table.push(_HuffmanEntry(0x7fffffeb, 27, 220))
      table.push(_HuffmanEntry(0xffffffe, 28, 221))
      table.push(_HuffmanEntry(0x7fffffec, 27, 222))
      table.push(_HuffmanEntry(0x7fffffed, 27, 223))
      table.push(_HuffmanEntry(0x7fffffee, 27, 224))
      table.push(_HuffmanEntry(0x7fffffef, 27, 225))
      table.push(_HuffmanEntry(0x7ffffff0, 27, 226))
      table.push(_HuffmanEntry(0x3fffffeC, 26, 227))
      table.push(_HuffmanEntry(0x3fffffeD, 26, 228))
      table.push(_HuffmanEntry(0x7ffffff1, 27, 229))
      table.push(_HuffmanEntry(0x3fffffeE, 26, 230))
      table.push(_HuffmanEntry(0x7ffffff2, 27, 231))
      table.push(_HuffmanEntry(0x7ffffff3, 27, 232))
      table.push(_HuffmanEntry(0x7ffffff4, 27, 233))
      table.push(_HuffmanEntry(0x7ffffff5, 27, 234))
      table.push(_HuffmanEntry(0x7ffffff6, 27, 235))
      table.push(_HuffmanEntry(0x7ffffff7, 27, 236))
      table.push(_HuffmanEntry(0x7ffffff8, 27, 237))
      table.push(_HuffmanEntry(0x7ffffff9, 27, 238))
      table.push(_HuffmanEntry(0x7ffffffa, 27, 239))
      table.push(_HuffmanEntry(0x7ffffffb, 27, 240))
      table.push(_HuffmanEntry(0x7ffffffc, 27, 241))
      table.push(_HuffmanEntry(0x7ffffffd, 27, 242))
      table.push(_HuffmanEntry(0x7ffffffe, 27, 243))
      table.push(_HuffmanEntry(0x7fffffff, 27, 244))
      table.push(_HuffmanEntry(0x3fffffeF, 26, 245))
      table.push(_HuffmanEntry(0x3ffffff0, 26, 246))
      table.push(_HuffmanEntry(0x3ffffff1, 26, 247))
      table.push(_HuffmanEntry(0x3ffffff2, 26, 248))
      table.push(_HuffmanEntry(0x3ffffff3, 26, 249))
      table.push(_HuffmanEntry(0x3ffffff4, 26, 250))
      table.push(_HuffmanEntry(0x3ffffff5, 26, 251))
      table.push(_HuffmanEntry(0x3ffffff6, 26, 252))
      table.push(_HuffmanEntry(0x3ffffff7, 26, 253))
      table.push(_HuffmanEntry(0x3ffffff8, 26, 254))
      table.push(_HuffmanEntry(0x3ffffff9, 26, 255))
      // EOS symbol - special marker, not a valid character
      table.push(_HuffmanEntry(0x3ffffffa, 30, 0, true))
      consume table
    end

  fun decode(data: Array[U8] val): (String | None) ? =>
    """
    Decode Huffman-encoded data.
    Returns None if decoding fails.

    Per RFC 7541 Section 5.2:
    - Padding must be 1-7 bits
    - Padding bits must be all 1s (EOS symbol prefix)
    - EOS symbol must not appear in the encoded data
    """
    if data.size() == 0 then
      return ""
    end

    let table = _huffman_table()
    let result = recover String end
    result.reserve(data.size() * 2) // Estimate output size

    var current_bits: U32 = 0
    var bits_in_buffer: U8 = 0
    var byte_pos: USize = 0

    while byte_pos < data.size() do
      // Add next byte to buffer
      current_bits = (current_bits << 8) or data(byte_pos)?.u32()
      bits_in_buffer = bits_in_buffer + 8
      byte_pos = byte_pos + 1

      // Try to decode symbols from buffer
      while bits_in_buffer > 0 do
        var matched = false

        // Try each Huffman code in the table
        for entry in table.values() do
          if entry.length <= bits_in_buffer then
            // Extract top entry.length bits from buffer
            let shift = bits_in_buffer - entry.length
            let mask: U32 = (1 << entry.length.u32()) - 1
            let code = (current_bits >> shift.u32()) and mask

            if code == entry.code then
              // Found a match
              // Check if this is the EOS symbol
              // The EOS symbol is a special marker for end-of-string, not a valid character
              if entry.is_eos then
                // EOS symbol found - this is an error per RFC 7541
                // EOS must not appear in the encoded data itself
                return None
              end

              result.push(entry.symbol)
              bits_in_buffer = bits_in_buffer - entry.length

              // Clear consumed bits
              let clear_mask: U32 = (1 << bits_in_buffer.u32()) - 1
              current_bits = current_bits and clear_mask

              matched = true
              break
            end
          end
        end

        if not matched then
          // No match found, need more bits
          break
        end
      end
    end

    // Handle remaining bits (should be padding)
    // Per RFC 7541 Section 5.2:
    // - Padding must be 0-7 bits (shorter than 8 bits)
    // - Padding bits must be all 1s (the prefix of the EOS symbol)
    // - Note: 0 bits of padding is allowed when string ends on byte boundary

    // Validate padding length: must be 0-7 bits (less than 8)
    if bits_in_buffer >= 8 then
      return None
    end

    // If there are remaining bits, validate they are all 1s
    if bits_in_buffer > 0 then
      // Validate padding bits: must be all 1s
      // The EOS symbol prefix is all 1s (0x3ffffffa has leading 1s)
      let padding_mask: U32 = (1 << bits_in_buffer.u32()) - 1
      if (current_bits and padding_mask) != padding_mask then
        // Padding contains zeros - this is an error per RFC 7541
        return None
      end
    end

    consume result

class HPACKDecoder
  """
  HPACK decoder per RFC 7541.

  Decodes header blocks into name-value pairs using the static and
  dynamic tables.

  This is a simplified implementation that handles basic HPACK decoding.
  """

  var _dynamic_table: Map[USize, (String, String)]
  var _dynamic_table_size: USize = 0
  var _max_table_size: USize = 4096
  // Per RFC 7541 Section 4.2: The maximum size of the dynamic table
  // as specified by the SETTINGS_HEADER_TABLE_SIZE setting
  var _settings_table_size: USize = 4096

  new create(max_table_size: USize = 4096) =>
    """
    Create a new HPACK decoder.
    """
    _dynamic_table = Map[USize, (String, String)]
    _max_table_size = max_table_size
    _settings_table_size = max_table_size

  fun ref set_max_table_size(size: USize) =>
    """
    Update the maximum dynamic table size from SETTINGS.
    Per RFC 7541 Section 4.2: This updates both the current limit
    and the SETTINGS_HEADER_TABLE_SIZE limit used for validation.
    """
    _max_table_size = size
    _settings_table_size = size
    // Evict entries if necessary
    _evict_entries()

  fun ref _evict_entries() =>
    """
    Evict entries from the dynamic table if over size limit.
    """
    // Simplified: clear if over limit
    if _dynamic_table_size > _max_table_size then
      _dynamic_table.clear()
      _dynamic_table_size = 0
    end

  fun ref decode(data: Array[U8] val): (Array[(String, String)] | None) =>
    """
    Decode a header block into an array of (name, value) pairs.
    Returns None if decoding fails.
    """
    let result = Array[(String, String)]
    var pos: USize = 0
    // Maximum iterations to prevent infinite loops on malformed data
    let max_iterations: USize = 1024
    var iterations: USize = 0
    // Track if we've seen any header fields (not including dynamic table updates)
    // Per RFC 7541 Section 4.2: Dynamic table size updates MUST occur at the
    // beginning of the header block, before any header fields
    var seen_header_fields: Bool = false

    while pos < data.size() do
      // Safety check: ensure we don't loop infinitely
      if iterations >= max_iterations then
        return None
      end
      iterations = iterations + 1

      // Track position at start of iteration to ensure we make progress
      let start_pos = pos

      try
        if pos >= data.size() then
          error
        end

        let first_byte = data(pos)?

        // Check the prefix bits to determine the representation type
        if (first_byte and 0x80) != 0 then
          // Indexed Header Field (1-bit prefix)
          let idx_result = _decode_integer(data, pos, 7)?
          let index = idx_result._1
          let bytes_read = idx_result._2

          if index == 0 then
            error  // Index 0 is not valid
          end

          let lookup = _lookup_index(index)?
          result.push(lookup)
          pos = pos + bytes_read
          seen_header_fields = true

        elseif (first_byte and 0xC0) == 0x40 then
          // Literal Header Field with Incremental Indexing (6-bit prefix)
          let idx_result = _decode_integer(data, pos, 6)?
          let index = idx_result._1
          let index_bytes = idx_result._2

          var current_pos = pos + index_bytes

          // Get the name
          var name: String = ""
          if index == 0 then
            // Name is a literal string
            let str_result = _decode_string(data, current_pos)?
            name = str_result._1
            current_pos = current_pos + str_result._2
          else
            // Name is from the table
            let lookup = _lookup_index(index)?
            name = lookup._1
          end

          // Get the value (always literal)
          let val_result = _decode_string(data, current_pos)?
          let value = val_result._1
          current_pos = current_pos + val_result._2

          // Add to dynamic table
          _add_to_dynamic_table(name, value)

          result.push((name, value))
          pos = current_pos
          seen_header_fields = true

        elseif (first_byte and 0xF0) == 0x00 then
          // Literal Header Field without Indexing (4-bit prefix)
          let idx_result = _decode_integer(data, pos, 4)?
          let index = idx_result._1
          let index_bytes = idx_result._2

          var current_pos = pos + index_bytes

          // Get the name
          var name: String = ""
          if index == 0 then
            let str_result = _decode_string(data, current_pos)?
            name = str_result._1
            current_pos = current_pos + str_result._2
          else
            let lookup = _lookup_index(index)?
            name = lookup._1
          end

          // Get the value
          let val_result = _decode_string(data, current_pos)?
          let value = val_result._1
          current_pos = current_pos + val_result._2

          result.push((name, value))
          pos = current_pos
          seen_header_fields = true

        elseif (first_byte and 0xF0) == 0x10 then
          // Literal Header Field Never Indexed (4-bit prefix)
          // Same as without indexing
          let idx_result = _decode_integer(data, pos, 4)?
          let index = idx_result._1
          let index_bytes = idx_result._2

          var current_pos = pos + index_bytes

          var name: String = ""
          if index == 0 then
            let str_result = _decode_string(data, current_pos)?
            name = str_result._1
            current_pos = current_pos + str_result._2
          else
            let lookup = _lookup_index(index)?
            name = lookup._1
          end

          let val_result = _decode_string(data, current_pos)?
          let value = val_result._1
          current_pos = current_pos + val_result._2

          result.push((name, value))
          pos = current_pos
          seen_header_fields = true

        elseif (first_byte and 0xE0) == 0x20 then
          // Dynamic Table Size Update (5-bit prefix)
          // Per RFC 7541 Section 4.2: Dynamic table size updates MUST occur at
          // the beginning of the header block, before any header fields
          if seen_header_fields then
            // Dynamic table size update after header fields - COMPRESSION_ERROR
            return None
          end
          let size_result = _decode_integer(data, pos, 5)?
          let new_size = size_result._1
          let bytes_read = size_result._2
          // Per RFC 7541 Section 4.2: A dynamic table size update with a new size
          // larger than the value of SETTINGS_HEADER_TABLE_SIZE must be treated
          // as a decoding error (COMPRESSION_ERROR)
          // Per RFC 7541 Section 4.2: A dynamic table size update with a new size
          // larger than the value of SETTINGS_HEADER_TABLE_SIZE must be treated
          // as a decoding error (COMPRESSION_ERROR)
          if new_size > _settings_table_size then
            return None
          end
          // Update current max table size (this can be reduced by updates)
          _max_table_size = new_size
          pos = pos + bytes_read
        else
          error
        end

        // Safety check: ensure position always advances
        if pos <= start_pos then
          return None
        end
      else
        // Decoding error
        return None
      end
    end

    result

  fun ref _lookup_index(index: USize): (String, String) ? =>
    """
    Look up a header by index in static or dynamic table.
    Per RFC 7541: An index that is greater than the sum of the sizes of both
    tables MUST be treated as a decoding error (COMPRESSION_ERROR).
    """
    if index == 0 then
      error  // Index 0 is not valid
    end
    if index <= _static_table_size() then
      // Static table (1-based index)
      (_static_table_name(index), _static_table_value(index))
    else
      // Dynamic table: index 62 = most recent entry
      // Our _dynamic_table stores entries with increasing keys (1, 2, 3...)
      // where higher key = more recent entry
      // So we need to map: index 62 -> highest key, index 63 -> second highest, etc.
      let dynamic_offset = index - _static_table_size()  // 1 for first dynamic index
      let dynamic_index = (_dynamic_table_size - dynamic_offset) + 1
      if (dynamic_index < 1) or (dynamic_index > _dynamic_table_size) then
        // Index out of range - this is a COMPRESSION_ERROR per RFC 7541
        error
      else
        try
          _dynamic_table(dynamic_index)?
        else
          // Should not happen if indices are correct
          error
        end
      end
    end

  fun _static_table_size(): USize => 61

  fun _static_table_name(index: USize): String =>
    """
    Get the header name for a static table index (1-based).
    """
    match index
    | 1 => ":authority"
    | 2 | 3 => ":method"
    | 4 | 5 => ":path"
    | 6 | 7 => ":scheme"
    | 8 | 9 | 10 | 11 | 12 | 13 | 14 => ":status"
    | 15 => "accept-charset"
    | 16 => "accept-encoding"
    | 17 => "accept-language"
    | 18 => "accept-ranges"
    | 19 => "accept"
    | 20 => "access-control-allow-origin"
    | 21 => "age"
    | 22 => "allow"
    | 23 => "authorization"
    | 24 => "cache-control"
    | 25 => "content-disposition"
    | 26 => "content-encoding"
    | 27 => "content-language"
    | 28 => "content-length"
    | 29 => "content-location"
    | 30 => "content-range"
    | 31 => "content-type"
    | 32 => "cookie"
    | 33 => "date"
    | 34 => "etag"
    | 35 => "expect"
    | 36 => "expires"
    | 37 => "from"
    | 38 => "host"
    | 39 => "if-match"
    | 40 => "if-modified-since"
    | 41 => "if-none-match"
    | 42 => "if-range"
    | 43 => "if-unmodified-since"
    | 44 => "last-modified"
    | 45 => "link"
    | 46 => "location"
    | 47 => "max-forwards"
    | 48 => "proxy-authenticate"
    | 49 => "proxy-authorization"
    | 50 => "range"
    | 51 => "referer"
    | 52 => "refresh"
    | 53 => "retry-after"
    | 54 => "server"
    | 55 => "set-cookie"
    | 56 => "strict-transport-security"
    | 57 => "transfer-encoding"
    | 58 => "user-agent"
    | 59 => "vary"
    | 60 => "via"
    | 61 => "www-authenticate"
    else
      ""
    end

  fun _static_table_value(index: USize): String =>
    """
    Get the header value for a static table index (1-based).
    """
    match index
    | 2 => "GET"
    | 3 => "POST"
    | 4 => "/"
    | 5 => "/index.html"
    | 6 => "http"
    | 7 => "https"
    | 8 => "200"
    | 9 => "204"
    | 10 => "206"
    | 11 => "304"
    | 12 => "400"
    | 13 => "404"
    | 14 => "500"
    | 16 => "gzip, deflate"
    else
      ""
    end

  fun _decode_integer(
    data: Array[U8] val,
    pos: USize,
    prefix_bits: U8): (USize, USize) ?
  =>
    """
    Decode an integer representation (Section 5.1).
    Returns (value, bytes_consumed).
    """
    if pos >= data.size() then
      error
    end

    let max_prefix = (1 << prefix_bits.u32()) - 1
    let mask = max_prefix.u8()

    var value = (data(pos)? and mask).usize()
    var bytes_consumed: USize = 1

    if value < max_prefix.usize() then
      return (value, bytes_consumed)
    end

    // Multi-byte encoding
    var m: USize = 0
    // Maximum iterations to prevent infinite loop on malformed data
    // RFC 7541 allows integers up to 2^31-1, which needs at most 5 bytes
    let max_iterations: USize = 10
    var iterations: USize = 0

    while iterations < max_iterations do
      if (pos + bytes_consumed) >= data.size() then
        error
      end

      let b = data(pos + bytes_consumed)?
      bytes_consumed = bytes_consumed + 1

      // Check for shift overflow - max shift for USize is 63 on 64-bit systems
      // Using a safe constant since USize is at least 32 bits
      if m >= 57 then  // 64 - 7 = 57, safe for both 32 and 64 bit
        error
      end

      value = value + ((b and 0x7F).usize() << m)
      m = m + 7
      iterations = iterations + 1

      if (b and 0x80) == 0 then
        break
      end

      // If we've hit max iterations and still haven't terminated, error
      if iterations >= max_iterations then
        error
      end
    end

    (value, bytes_consumed)

  fun _decode_string(
    data: Array[U8] val,
    pos: USize): (String, USize) ?
  =>
    """
    Decode a string literal (Section 5.2).
    Returns (string, bytes_consumed).
    """
    if pos >= data.size() then
      error
    end

    let first_byte = data(pos)?
    let huffman = (first_byte and 0x80) != 0

    let len_result = _decode_integer(data, pos, 7)?
    let length = len_result._1
    let length_bytes = len_result._2

    // Validate string length is reasonable
    // RFC 7540 recommends a maximum header size of 16KB
    // We allow up to 64KB for safety
    let max_string_length: USize = 65536
    if length > max_string_length then
      error
    end

    var current_pos = pos + length_bytes

    // Check for overflow in position calculation
    if current_pos < pos then
      error
    end

    if (current_pos + length) > data.size() then
      error
    end

    // Check for overflow in length addition
    if (current_pos + length) < current_pos then
      error
    end

    let str_data = recover
      let arr = Array[U8]
      arr.reserve(length)
      for i in Range(current_pos, current_pos + length) do
        try
          arr.push(data(i)?)
        end
      end
      consume arr
    end

    let result = if huffman then
      _decode_huffman(consume str_data)?
    else
      _bytes_to_string(consume str_data)
    end

    (result, length_bytes + length)

  fun _decode_huffman(data: Array[U8] val): String ? =>
    """
    Decode Huffman-encoded string using RFC 7541 Appendix B.
    Returns error if decoding fails (to trigger COMPRESSION_ERROR).
    """
    match _HuffmanDecoder.decode(data)?
    | let s: String => s
    else
      // Decoding failed - propagate error to trigger COMPRESSION_ERROR
      error
    end

  fun _bytes_to_string(data: Array[U8] val): String =>
    """
    Convert byte array to string.
    """
    let s = recover String end
    s.reserve(data.size())
    for b in data.values() do
      s.push(b)
    end
    consume s

  fun ref _add_to_dynamic_table(name: String, value: String) =>
    """
    Add an entry to the dynamic table.
    """
    _dynamic_table_size = _dynamic_table_size + 1
    _dynamic_table.insert(_dynamic_table_size, (name, value))
    _evict_entries()

class HPACKEncoder
  """
  HPACK encoder per RFC 7541.

  Encodes header fields into a header block using the static and
  dynamic tables.

  This is a simplified encoder that uses literal encoding without
  indexing for simplicity. A full implementation would use indexing
  for better compression.
  """

  var _dynamic_table: Map[USize, (String, String)]
  var _dynamic_table_size: USize = 0
  var _max_table_size: USize = 4096

  new create(max_table_size: USize = 4096) =>
    """
    Create a new HPACK encoder.
    """
    _dynamic_table = Map[USize, (String, String)]
    _max_table_size = max_table_size

  fun ref set_max_table_size(size: USize) =>
    """
    Update the maximum dynamic table size.
    """
    _max_table_size = size

  fun ref encode(headers: Array[(String, String)] val): Array[U8] iso^ =>
    """
    Encode an array of (name, value) pairs into a header block.
    Returns iso array that can be consumed by the caller.

    We build inside recover iso so the result is already iso.
    Since 'headers' is val, it can be accessed inside recover.
    """
    HPACKEncodeHelper.encode_headers(headers)

  fun box _find_in_static_table(name: String, value: String): USize =>
    """
    Find a header in the static table.
    Returns index if found, 0 otherwise.
    """
    // Check for exact match (name + value)
    for i in Range(1, 62) do
      if (_static_table_name(i) == name) and
         (_static_table_value(i) == value) then
        return i
      end
    end
    0

  fun box _static_table_name(index: USize): String =>
    match index
    | 1 => ":authority"
    | 2 | 3 => ":method"
    | 4 | 5 => ":path"
    | 6 | 7 => ":scheme"
    | 8 | 9 | 10 | 11 | 12 | 13 | 14 => ":status"
    | 15 => "accept-charset"
    | 16 => "accept-encoding"
    | 17 => "accept-language"
    | 18 => "accept-ranges"
    | 19 => "accept"
    | 20 => "access-control-allow-origin"
    | 21 => "age"
    | 22 => "allow"
    | 23 => "authorization"
    | 24 => "cache-control"
    | 25 => "content-disposition"
    | 26 => "content-encoding"
    | 27 => "content-language"
    | 28 => "content-length"
    | 29 => "content-location"
    | 30 => "content-range"
    | 31 => "content-type"
    | 32 => "cookie"
    | 33 => "date"
    | 34 => "etag"
    | 35 => "expect"
    | 36 => "expires"
    | 37 => "from"
    | 38 => "host"
    | 39 => "if-match"
    | 40 => "if-modified-since"
    | 41 => "if-none-match"
    | 42 => "if-range"
    | 43 => "if-unmodified-since"
    | 44 => "last-modified"
    | 45 => "link"
    | 46 => "location"
    | 47 => "max-forwards"
    | 48 => "proxy-authenticate"
    | 49 => "proxy-authorization"
    | 50 => "range"
    | 51 => "referer"
    | 52 => "refresh"
    | 53 => "retry-after"
    | 54 => "server"
    | 55 => "set-cookie"
    | 56 => "strict-transport-security"
    | 57 => "transfer-encoding"
    | 58 => "user-agent"
    | 59 => "vary"
    | 60 => "via"
    | 61 => "www-authenticate"
    else
      ""
    end

  fun box _static_table_value(index: USize): String =>
    match index
    | 2 => "GET"
    | 3 => "POST"
    | 4 => "/"
    | 5 => "/index.html"
    | 6 => "http"
    | 7 => "https"
    | 8 => "200"
    | 9 => "204"
    | 10 => "206"
    | 11 => "304"
    | 12 => "400"
    | 13 => "404"
    | 14 => "500"
    | 16 => "gzip, deflate"
    else
      ""
    end

  fun _encode_indexed(buf: Array[U8], index: USize) =>
    """
    Encode an indexed header field (Section 6.1).
    """
    // 1-bit prefix (1), then 7-bit index
    _encode_integer(buf, index, 7, 0x80)

  fun _encode_literal_no_index(
    buf: Array[U8]
  ,
    name: String,
    value: String)
  =>
    """
    Encode a literal header field without indexing (Section 6.2.2).
    """
    // Check if name is in static table
    let name_index = _find_name_in_static_table(name)

    if name_index > 0 then
      // 4-bit prefix (0000), then 4-bit index
      _encode_integer(buf, name_index, 4, 0x00)
    else
      // Literal name - encode 0, then name as string
      buf.push(0x00)
      _encode_string(buf, name)
    end

    // Encode value as string
    _encode_string(buf, value)

  fun box _find_name_in_static_table(name: String): USize =>
    """
    Find a header name in the static table.
    Returns index if found, 0 otherwise.
    """
    for i in Range(1, 62) do
      if _static_table_name(i) == name then
        return i
      end
    end
    0

  fun box _encode_string(buf: Array[U8], s: String) =>
    """
    Encode a string literal (Section 5.2).
    """
    // For simplicity, encode as literal (not Huffman)
    // 7-bit prefix (0 for literal), then length, then data
    _encode_integer(buf, s.size(), 7, 0x00)

    // Append string bytes
    for i in Range(0, s.size()) do
      try
        buf.push(s(i)?)
      end
    end

  fun box _encode_integer(
    buf: Array[U8],
    value: USize,
    prefix_bits: U8,
    prefix_mask: U8)
  =>
    """
    Encode an integer representation (Section 5.1).
    """
    let max_prefix = ((1 << prefix_bits.u32()) - 1).usize()

    if value < max_prefix then
      // Single byte
      buf.push(prefix_mask or value.u8())
    else
      // Multi-byte encoding
      buf.push(prefix_mask or max_prefix.u8())

      var remaining = value - max_prefix
      while remaining >= 128 do
        buf.push((remaining % 128).u8() or 0x80)
        remaining = remaining / 128
      end
      buf.push(remaining.u8())
    end


primitive HPACKEncodeHelper
  """
  Helper primitive for HPACK encoding that doesn't have self reference issues.
  All methods are box so they can be called from within recover blocks.
  """
  fun encode_headers(headers: Array[(String, String)] val): Array[U8] iso^
  =>
    """
    Encode headers to an iso array.
    """
    recover iso
      let result = Array[U8]

      for (name, value) in headers.values() do
        // Try to find in static table first
        let index = _find_in_static_table(name, value)

        if index > 0 then
          // Found exact match - use indexed representation
          // 1-bit prefix (1), then 7-bit index
          _encode_integer(result, index, 7, 0x80)
        else
          // Use literal without indexing
          // Check if name is in static table
          let name_index = _find_name_in_static_table(name)

          if name_index > 0 then
            // 4-bit prefix (0000), then 4-bit index
            _encode_integer(result, name_index, 4, 0x00)
          else
            // Literal name - encode 0, then name as string
            result.push(0x00)
            _encode_string(result, name)
          end

          // Encode value as string
          _encode_string(result, value)
        end
      end

      result
    end

  fun _find_in_static_table(name: String, value: String): USize =>
    """
    Find a header in the static table.
    """
    for i in Range(1, 62) do
      if (_static_table_name(i) == name) and
         (_static_table_value(i) == value) then
        return i
      end
    end
    0

  fun _find_name_in_static_table(name: String): USize =>
    """
    Find a header name in the static table.
    """
    for i in Range(1, 62) do
      if _static_table_name(i) == name then
        return i
      end
    end
    0

  fun _static_table_name(index: USize): String =>
    match index
    | 1 => ":authority"
    | 2 | 3 => ":method"
    | 4 | 5 => ":path"
    | 6 | 7 => ":scheme"
    | 8 | 9 | 10 | 11 | 12 | 13 | 14 => ":status"
    | 15 => "accept-charset"
    | 16 => "accept-encoding"
    | 17 => "accept-language"
    | 18 => "accept-ranges"
    | 19 => "accept"
    | 20 => "access-control-allow-origin"
    | 21 => "age"
    | 22 => "allow"
    | 23 => "authorization"
    | 24 => "cache-control"
    | 25 => "content-disposition"
    | 26 => "content-encoding"
    | 27 => "content-language"
    | 28 => "content-length"
    | 29 => "content-location"
    | 30 => "content-range"
    | 31 => "content-type"
    | 32 => "cookie"
    | 33 => "date"
    | 34 => "etag"
    | 35 => "expect"
    | 36 => "expires"
    | 37 => "from"
    | 38 => "host"
    | 39 => "if-match"
    | 40 => "if-modified-since"
    | 41 => "if-none-match"
    | 42 => "if-range"
    | 43 => "if-unmodified-since"
    | 44 => "last-modified"
    | 45 => "link"
    | 46 => "location"
    | 47 => "max-forwards"
    | 48 => "proxy-authenticate"
    | 49 => "proxy-authorization"
    | 50 => "range"
    | 51 => "referer"
    | 52 => "refresh"
    | 53 => "retry-after"
    | 54 => "server"
    | 55 => "set-cookie"
    | 56 => "strict-transport-security"
    | 57 => "transfer-encoding"
    | 58 => "user-agent"
    | 59 => "vary"
    | 60 => "via"
    | 61 => "www-authenticate"
    else
      ""
    end

  fun _static_table_value(index: USize): String =>
    match index
    | 2 => "GET"
    | 3 => "POST"
    | 4 => "/"
    | 5 => "/index.html"
    | 6 => "http"
    | 7 => "https"
    | 8 => "200"
    | 9 => "204"
    | 10 => "206"
    | 11 => "304"
    | 12 => "400"
    | 13 => "404"
    | 14 => "500"
    | 16 => "gzip, deflate"
    else
      ""
    end

  fun _encode_string(buf: Array[U8], s: String) =>
    """
    Encode a string literal (Section 5.2).
    """
    // For simplicity, encode as literal (not Huffman)
    // 7-bit prefix (0 for literal), then length, then data
    _encode_integer(buf, s.size(), 7, 0x00)

    // Append string bytes
    for i in Range(0, s.size()) do
      try
        buf.push(s(i)?)
      end
    end

  fun _encode_integer(
    buf: Array[U8],
    value: USize,
    prefix_bits: U8,
    prefix_mask: U8)
  =>
    """
    Encode an integer representation (Section 5.1).
    """
    let max_prefix = ((1 << prefix_bits.u32()) - 1).usize()

    if value < max_prefix then
      // Single byte
      buf.push(prefix_mask or value.u8())
    else
      // Multi-byte encoding
      buf.push(prefix_mask or max_prefix.u8())

      var remaining = value - max_prefix
      while remaining >= 128 do
        buf.push((remaining % 128).u8() or 0x80)
        remaining = remaining / 128
      end
      buf.push(remaining.u8())
    end
