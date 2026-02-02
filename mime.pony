use "collections"

class val MimeTypes
  """
  MIME type detection for file extensions.

  Maps file extensions to MIME types per RFC 2045 and RFC 6838.
  Provides efficient lookup using pattern matching.

  Default MIME type for unknown extensions is "application/octet-stream"
  per RFC 2045 Section 5.2.
  """

  // Default MIME type for unknown extensions
  let default_mime_type: String val = "application/octet-stream"

  new val create() =>
    """
    Create a new MimeTypes instance.
    All data is immutable (val) for safe sharing across actors.
    """
    // No initialization needed - all data is in the match statement

  fun val get_mime_type(extension: String): String val =>
    """
    Get the MIME type for a file extension.

    The extension can be provided with or without a leading dot.
    Returns "application/octet-stream" for unknown extensions.

    Examples:
    - get_mime_type("html") returns "text/html"
    - get_mime_type(".html") returns "text/html"
    - get_mime_type("unknown") returns "application/octet-stream"
    """
    // Normalize the extension (remove leading dot if present and lowercase)
    let ext = _normalize_extension(extension)

    match ext
    // Text types
    | "html" | "htm" => "text/html"
    | "css" => "text/css"
    | "txt" | "text" => "text/plain"
    | "csv" => "text/csv"
    | "xml" => "text/xml"
    | "md" | "markdown" => "text/markdown"

    // JavaScript and related
    | "js" | "mjs" => "application/javascript"
    | "json" => "application/json"
    | "jsonld" => "application/ld+json"

    // Web fonts
    | "woff" => "font/woff"
    | "woff2" => "font/woff2"
    | "ttf" => "font/ttf"
    | "otf" => "font/otf"

    // Images
    | "png" => "image/png"
    | "jpg" | "jpeg" => "image/jpeg"
    | "gif" => "image/gif"
    | "svg" => "image/svg+xml"
    | "bmp" => "image/bmp"
    | "webp" => "image/webp"
    | "ico" => "image/x-icon"
    | "tiff" | "tif" => "image/tiff"

    // Audio
    | "mp3" => "audio/mpeg"
    | "wav" => "audio/wav"
    | "ogg" => "audio/ogg"
    | "oga" => "audio/ogg"
    | "aac" => "audio/aac"
    | "weba" => "audio/webm"

    // Video
    | "mp4" => "video/mp4"
    | "webm" => "video/webm"
    | "ogv" => "video/ogg"
    | "avi" => "video/x-msvideo"
    | "mpeg" | "mpg" => "video/mpeg"
    | "mov" => "video/quicktime"
    | "flv" => "video/x-flv"

    // Application types
    | "pdf" => "application/pdf"
    | "zip" => "application/zip"
    | "gz" | "gzip" => "application/gzip"
    | "tar" => "application/x-tar"
    | "rar" => "application/vnd.rar"
    | "7z" => "application/x-7z-compressed"
    | "bz2" => "application/x-bzip2"

    // Documents
    | "doc" => "application/msword"
    | "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    | "xls" => "application/vnd.ms-excel"
    | "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    | "ppt" => "application/vnd.ms-powerpoint"
    | "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation"
    | "odt" => "application/vnd.oasis.opendocument.text"
    | "ods" => "application/vnd.oasis.opendocument.spreadsheet"
    | "odp" => "application/vnd.oasis.opendocument.presentation"

    // Web-related
    | "wasm" => "application/wasm"
    | "swf" => "application/x-shockwave-flash"

    // Programming languages
    | "c" => "text/x-c"
    | "h" => "text/x-c"
    | "cpp" | "cc" | "cxx" => "text/x-c++"
    | "java" => "text/x-java"
    | "py" => "text/x-python"
    | "rb" => "text/x-ruby"
    | "go" => "text/x-go"
    | "rs" => "text/x-rust"
    | "php" => "application/x-httpd-php"
    | "pl" => "text/x-perl"
    | "sh" => "application/x-sh"
    | "bat" => "application/bat"

    // Data formats
    | "yaml" | "yml" => "application/yaml"
    | "toml" => "application/toml"
    | "ini" => "text/plain"
    | "sql" => "application/sql"

    // Archives and executables
    | "exe" => "application/x-msdownload"
    | "dll" => "application/x-msdownload"
    | "deb" => "application/vnd.debian.binary-package"
    | "rpm" => "application/x-rpm"
    | "dmg" => "application/x-apple-diskimage"
    | "iso" => "application/x-iso9660-image"

    // Default for unknown extensions
    else
      default_mime_type
    end

  fun val get_mime_type_from_path(path: String): String val =>
    """
    Extract the file extension from a path and return its MIME type.

    Handles paths with or without directories, and with or without query strings.
    Returns "application/octet-stream" if no extension is found or it's unknown.

    Examples:
    - get_mime_type_from_path("/path/to/file.html") returns "text/html"
    - get_mime_type_from_path("style.css?v=123") returns "text/css"
    - get_mime_type_from_path("file") returns "application/octet-stream"
    """
    let ext = extract_extension(path)
    if ext.size() > 0 then
      get_mime_type(ext)
    else
      default_mime_type
    end

  fun val extract_extension(path: String): String val =>
    """
    Extract the file extension from a path.

    Returns the extension without the leading dot, or empty string if no extension.
    Handles paths with directories, query strings, and fragments.

    Examples:
    - extract_extension("/path/to/file.html") returns "html"
    - extract_extension("style.css?v=123") returns "css"
    - extract_extension("/path/to/file") returns ""
    - extract_extension("archive.tar.gz") returns "gz"
    """
    // Find the last path separator
    var last_slash: ISize = -1
    var last_dot: ISize = -1
    var i: USize = 0

    // Find last slash and last dot positions
    while i < path.size() do
      try
        let c = path(i)?
        if (c == '/') or (c == '\\') then
          last_slash = i.isize()
        elseif c == '.' then
          // Only consider dots after the last slash
          if i.isize() > (last_slash + 1) then
            last_dot = i.isize()
          end
        elseif c == '?' then
          // Query string starts - stop here
          break
        elseif c == '#' then
          // Fragment starts - stop here
          break
        end
        i = i + 1
      else
        break
      end
    end

    // If no dot found, or dot is at the end, or dot is right after slash, no extension
    if (last_dot < 0) or (last_dot >= (path.size().isize() - 1)) then
      return ""
    end

    // Extract extension (everything after the last dot)
    let ext_size = path.size() - last_dot.usize() - 1
    if ext_size == 0 then
      return ""
    end

    recover
      let result = String(ext_size)
      var j = last_dot.usize() + 1
      while j < path.size() do
        try
          result.push(path(j)?)
        else
          break
        end
        j = j + 1
      end
      result.lower()
    end

  fun val _normalize_extension(extension: String): String val =>
    """
    Normalize an extension by removing leading dot and converting to lowercase.
    """
    recover
      let start: USize =
        if extension.size() > 0 then
          try
            if extension(0)? == '.' then
              1
            else
              0
            end
          else
            0
          end
        else
          0
        end

      let result = String(extension.size() - start)
      var i = start
      while i < extension.size() do
        try
          // Convert to lowercase manually
          var c = extension(i)?
          if (c >= 'A') and (c <= 'Z') then
            c = c + ('a' - 'A')
          end
          result.push(c)
        else
          break
        end
        i = i + 1
      end
      result
    end

  // Static convenience methods

  fun tag is_text_type(mime_type: String): Bool =>
    """
    Check if a MIME type represents text content.
    Useful for determining if content should be transferred as text or binary.
    """
    // Check if it starts with "text/"
    if mime_type.size() >= 5 then
      let prefix = mime_type.substring(0, 5)
      if prefix == "text/" then
        return true
      end
    end

    // Check for known text-based application types
    match mime_type
    | "application/javascript" => true
    | "application/json" => true
    | "application/xml" => true
    | "application/yaml" => true
    | "application/toml" => true
    | "application/sql" => true
    | "application/ld+json" => true
    | "application/x-httpd-php" => true
    | "application/x-sh" => true
    | "application/bat" => true
    else
      false
    end

  fun tag is_image_type(mime_type: String): Bool =>
    """
    Check if a MIME type represents an image.
    """
    if mime_type.size() >= 6 then
      let prefix = mime_type.substring(0, 6)
      prefix == "image/"
    else
      false
    end

  fun tag get_charset(mime_type: String): String val =>
    """
    Get the default charset for a MIME type.
    Returns "utf-8" for text types that typically use UTF-8,
    or empty string for binary types.
    """
    match mime_type
    | "text/html" | "text/css" | "text/plain" | "text/xml" |
      "text/csv" | "text/markdown" => "utf-8"
    | "application/javascript" | "application/json" |
      "application/xml" | "application/yaml" | "application/toml" => "utf-8"
    else
      ""
    end
