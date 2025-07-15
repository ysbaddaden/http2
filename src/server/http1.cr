require "http/common"
require "http/content"

module HTTP1
  struct Connection
    MAX_HEADERS_SIZE = 16_384

    getter io : IO
    getter! version : String

    def initialize(@io)
    end

    def read_request_line
      return unless line = @io.gets(chomp: true)

      return unless a = line.index(' ')
      method = line[0...a]

      return unless b = line.index(' ', a += 1)
      path = line[a...b]

      # OWS after version is invalid, but skip it anyway
      c = -1
      while line[c].ascii_whitespace?
        c -= 1
      end
      @version = line[(b + 1)..c]

      {method, path}
    end

    def read_headers(headers : HTTP::Headers) : Bool
      headers_size = 0

      loop do
        line = @io.read_line(MAX_HEADERS_SIZE, chomp: true)
        break if line.empty?

        headers_size += line.size
        return false if headers_size > MAX_HEADERS_SIZE

        return false unless a = line.index(':')
        name = line[0...a]

        # OWS before value
        a += 1
        while line[a].ascii_whitespace?
          a += 1
        end

        # OWS after value
        b = -1
        while line[b].ascii_whitespace?
          b -= 1
        end

        value = line[a..b]
        headers[name] = value
      end

      true
    end

    def upgrade(protocol : String)
      @io << @version << " 101 Switching Protocols\r\n"
      @io << "Connection: Upgrade\r\n"
      @io << "Upgrade: " << protocol << "\r\n"
      @io << "\r\n"
      @io.flush
    end

    def content(headers : HTTP::Headers, mandatory = false) : IO?
      if content_length = headers["Content-Length"]?.try(&.to_u64)
        return if content_length == 0
        HTTP::FixedLengthContent.new(@io, content_length)
      elsif headers["Transfer-Encoding"]? == "chunked"
        HTTP::ChunkedContent.new(@io)
      elsif mandatory
        HTTP::UnknownLengthContent.new(@io)
      end
    end

    def send_headers(headers : HTTP::Headers)
      status = headers[":status"]
      message = HTTP::Status.new(status.to_i).description
      @io << @version << ' ' << status << ' ' << message << "\r\n"

      headers.each do |name, values|
        if name.starts_with?(':')
          next
        end
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

    def send_data(string : String, chunked = false)
      send_data(string.to_slice, chunked)
    end

    def send_data(bytes : Bytes, chunked = false)
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

    def flush
      @io.flush
    end
  end
end
