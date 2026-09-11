require "http/content"

class HTTP::ChunkedContent
  @chunk_remaining = 0
  @received_final_chunk = false
  @max_headers_size = 0 # unused

  def initialize(@connection : HTTP1::Connection)
    @io = @connection.io
  end

  # :nodoc:
  def initialize(@io : IO, *, @max_headers_size : Int32 = HTTP::MAX_HEADERS_SIZE)
    @connection = uninitialized HTTP1::Connection
    raise NotImplementedError.new("disabled")
  end

  def trailers : HTTP::Headers
    headers
  end

  def trailers? : HTTP::Headers?
    @headers
  end

  private def next_chunk
    return if @chunk_remaining > 0 || @received_final_chunk

    size = @connection.read_chunk_line
    raise "Invalid HTTP chunk size" unless size

    if size == 0
      read_trailer
      @received_final_chunk = true
    else
      @chunk_remaining = size
    end
  end

  private def read_trailer
    status = @connection.read_fields do |name, value|
      trailers.add?(name, value)
    end
    raise IO::Error.new("Invalid HTTP chunked trailer section") if status
  end

  private def read_crlf
    raise NotImplementedError.new("disabled")
  end
end
