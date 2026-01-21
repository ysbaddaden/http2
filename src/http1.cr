require "http/common"
require "http/content"

module HTTP1
  class Connection
    private LF = 0x0a_u8
    private CR = 0x0d_u8
    private SP = 0x20_u8
    private COLON = 0x58_u8

    getter io : IO
    property version : String

    # A faulty client connection SHOULD still process the current request, but
    # MUST close the connection immediately after it to avoid request smuggling
    # and request splitting security issues (no keep-alive, no pipeline).
    getter? faulty : Bool = true

    def initialize(@io, @version : String = "HTTP/1.1")
    end

    # Limit the request line bytesize. As per RFC 9112, Section 3. it should be
    # at least 8000 bytes long. Defaults to 8KB.
    property max_request_line_size : Int32 = 8192

    # Limit the status line bytesize. As per RFC 9112, Section 3. it should be
    # at least 8000 bytes long. Defaults to 4KB.
    property max_status_line_size : Int32 = 4096

    # Limit the overall headers bytesize. Defaults to 16KB.
    property max_headers_size : Int32 = 16384

    # Peek into the IO buffer to see if a whole line is available (that should
    # usually be the case). Fall backs to allocate a String to read a full line.
    private def read_line(max_line_size, too_long, &)
      if peek = io.peek
        return if peek.empty? # EOF

        # Search LF. If not found the request line isn't fully read in the
        # IO buffer and we must fallback to allocate a String.
        if index = peek.index(LF)
          return too_long if index > max_line_size

          size = index
          size -= 1 if index > 0 && peek[index - 1] == CR
          value = yield(peek[0, size])

          io.skip(index + 1) # seek IO to the byte just after LF

          return value
        end
      end

      # Can't peek or didn't find LF: read line from IO; we put the limit at +1
      # byte so we can detect the limit, while never reading past the LF char.
      return unless line = io.gets(max_line_size + 1, chomp: true)
      too_long if line.bytesize > max_line_size

      yield line.to_slice
    end

    def read_request_line : {String, String} | HTTP::Status | Nil
      read_line(max_request_line_size, HTTP::Status::URI_TOO_LONG) do |slice|
        if slice == "PRI * HTTP/2.0".to_slice
          @version = "HTTP/2.0"
          return {"PRI", "*"}
        end

        # request-line = method SP+ request-target SP+ HTTP-version SP* [CR] LF
        space_index = slice.index(SP)
        return HTTP::Status::BAD_REQUEST unless space_index

        # Use static string for common methods instead of allocating a String
        method =
          {% begin %}
          case subslice = slice[0, space_index]
          {% for method in %w[GET HEAD POST PUT DELETE PATCH OPTIONS CONNECT TRACE] %}
          when {{method}}.to_slice
            {{method}}
          {% end %}
          else
            String.new(subslice)
          end
          {% end %}
        slice += space_index

        # Per RFC 9112, Section 3. there MUST be a single SP but implementations
        # MAY skip any whitespace character (SP, HTAB, VT, FF and a lone CR).
        # Here we merely skip multiple SP.
        while slice.first? == SP
          slice += 1
        end

        # request-target
        space_index = slice.index(SP)
        return HTTP::Status::BAD_REQUEST unless space_index

        path = String.new(slice[0, space_index])
        slice += space_index

        # SP
        while slice.first? == SP
          slice += 1
        end

        # HTTP-version
        space_index = slice.index(SP) || slice.size
        case slice[0, space_index]
        when "HTTP/1.0".to_slice
          @version = "HTTP/1.0"
        when "HTTP/1.1".to_slice
          @version = "HTTP/1.1"
        else
          return HTTP::Status::BAD_REQUEST
        end
        slice += space_index

        # SP* EOL
        while byte = slice.first?
          return HTTP::Status::BAD_REQUEST unless byte == SP
          slice += 1
        end

        {method, path}
      end
    end

    def read_status_line : {String, Int32, String}
      read_line(max_status_line_size, nil) do |slice|
        # status-line = HTTP-version SP+ status SP+ reason-phrase SP* [CR] LF
        space_index = slice.index(SP)
        raise "Invalid status line" unless space_index

        version =
          case subslice = slice[0, space_index]
          when "HTTP/1.0".to_slice
            "HTTP/1.0"
          when "HTTP/1.1".to_slice
            "HTTP/1.1"
          else
            raise "Unsupported HTTP version #{String.new(subslice)}"
          end
        slice += space_index

        # Per RFC 9112, Section 4. there MUST be a single SP but implementations
        # MAY skip any whitespace character (SP, HTAB, VT, FF and a lone CR).
        # Here we merely skip multiple SP.
        while slice.first? == SP
          slice += 1
        end

        # status (3 digits)
        space_index = slice.index(SP) || slice.size
        subslice = slice[0, space_index]
        status = subslice.reduce(0) do |acc, byte|
          case byte
          when ('0'.ord)..('9'.ord)
            acc * 10 + (byte - '0'.ord)
          else
            raise "Invalid HTTP status code: #{String.new(subslice)}"
          end
        end
        raise "Invalid HTTP status code: #{status}" unless 100 <= status <= 999
        slice += 3

        # SP
        while slice.first? == SP
          slice += 1
        end

        # reason-phrase (optional, legacy, could be discarded)
        description = ""
        unless slice.empty?
          size = slice.size
          while slice.last? == SP
            size = -1
          end
          description = String.new(slice[0, size]) unless slice.empty?
        end

        {version, status, description}
      end
    end

    def read_fields(fields : HTTP::Headers) : HTTP::Status?
      total = 0

      loop do
        read_line(MAX_HEADERS_SIZE, HTTP::Status::REQUEST_HEADER_FIELDS_TOO_LARGE) do |slice|
          return if slice.empty?

          if (total += slice.size) > MAX_HEADERS_SIZE
            return HTTP::Status::REQUEST_HEADER_FIELDS_TOO_LARGE
          end

          # field-line = field-name ':' OWS field-value OWS [CR] LF
          colon_index = slice.index(COLON)
          return HTTP::Status::BAD_REQUEST unless colon_index

          name = field_name(slice[0, colon_index])
          slice += colon_index + 1

          # OWS before field-value
          while slice.first? == SP
            slice += 1
          end

          # OWS after field-value
          size = -1
          while slice[size] == SP
            size -= 1
          end

          value = String.new(slice[0, size])
          {name, value}

          return HTTP::Status::BAD_REQUEST unless fields.add?(name, value)
        end
      end
    end

    private def field_name(slice)
      # use static strings whenever possible, lower cased to match HPACK table
      {% for name in %w[
        accept-charset
        accept-encoding
        accept-language
        accept-ranges
        accept
        access-control-allow-origin
        age
        allow
        authorization
        cache-control
        content-disposition
        content-encoding
        content-language
        content-length
        content-location
        content-range
        content-type
        cookie
        date
        etag
        expect
        expires
        from
        host
        if-match
        if-modified-since
        if-none-match
        if-range
        if-unmodified-since
        last-modified
        link
        location
        max-forwards
        proxy-authenticate
        proxy-authorization
        range
        referer
        refresh
        retry-after
        server
        set-cookie
        strict-transport-security
        transfer-encoding
        user-agent
        vary
        via
        www-authenticate
      ] %}
      return {{name}} if case_insensitive_eq?({{name}}, slice)
      {% end %}

      # fallback: allocate a string
      String.new(slice)
    end

    private def case_insensitive_eq?(name, slice)
      return false unless name.bytesize == slice.size

      a, b = string.to_unsafe, slice.to_unsafe
      limit = a + name.bytesize

      until a == limit
        return false unless a == b # fast-path
        return false unless normalize_byte(a) == normalize_byte(b) # slow-path
        a += 1
        b += 1
      end

      true
    end

    private def normalize_byte(byte)
      if 'A'.ord <= byte <= 'Z'.ord
        byte + 32
      elsif byte == '_'.ord
        '-'.ord
      else
        byte
      end
    end

    def http2_upgrade(protocol : String) : Nil
      @io << version << " 101 Switching Protocols\r\n"
      @io << "Connection: Upgrade\r\n"
      @io << "Upgrade: " << protocol << "\r\n"
      @io << "\r\n"
      @io.flush
    end

    def content(headers : HTTP::Headers, mandatory = false) : IO?
      content_length = HTTP.content_length(headers)
      transfer_encoding = headers["transfer-encoding"]?

      # RFC 9112, Section 6.1 says that a server receiving a request with both
      # headers MUST close the connection after processing it to avoid request
      # smuggling and request splitting security issues.
      if content_length && transfer_encoding
        @faulty = true
      end

      # FIXME: transfer-encoding may be "gzip, chunked" for example, which means
      # that the body has been compressed with gzip then chunked encoded (and
      # thus must be decoded as chunked)
      if transfer_encoding == "chunked"
        body = HTTP::ChunkedContent.new(@io)
      elsif content_length
        body = HTTP::FixedLengthContent.new(@io, content_length)
      elsif mandatory
        body = HTTP::UnknownLengthContent.new(@io)
      end

      if body.is_a?(HTTP::Content) && (expect = headers["expect"]?)
        if expect.compare("100-continue", case_insensitive: true) == 0
          body.expect_continue = true
        end
      end

      body
    end

    def write_request_line(method : String, path : String) : Nil
      @io << method << ' ' << path << ' ' << version << "\r\n"
    end

    def write_status_line(status : String | Int32, path : String, description : String) : Nil
      @io << version << ' ' << status << ' ' << description << "\r\n"
    end

    def write_fields(fields : Headers) : Nil
      fields.each do |name, values|
        next if name.starts_with?(':')

        if name.compare("set-cookie", case_insensitive: true) == 0
          values.each do |value|
            @io << name << ": " << value << "\r\n"
          end
        else
          @io << name << ": "
          values.join(@io, ", ")
          @io << "\r\n"
        end
      end
      @io << "\r\n"
    end

    def write_data(bytes : Bytes, chunked = false) : Nil
      if chunked
        if bytes.size == 0
          @io << "0\r\n\r\n"
        else
          bytes.size.to_s(@io, 16)
          @io << "\r\n"
          @io.write(bytes)
          @io << "\r\n"
        end
      else
        @io.write(bytes)
      end
    end

    def send_headers(headers : HTTP::Headers, description : String? = nil) : Nil
      if status = headers[":status"]?
        description ||= HTTP::Status.new(status.to_i).description
        write_status_line(status, description)
      elsif (method = headers[":method"]?) || (path = headers[":path"]?)
        write_request_line(method, path)
      else
        raise ArgumentError.new(%(Missing ":status" (response) or ":method" and ":path" (request) pseudo-headers))
      end
      write_fields(headers)
    end

    def send_data(data : String, chunked : Bool = false) : Nil
      write_data(data.to_slice, chunked)
    end

    def send_data(data : Slice, chunked : Bool = false) : Nil
      write_data(data, chunked)
    end

    def flush : Nil
      @io.flush
    end
  end
end
