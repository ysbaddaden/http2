# Overloads HTTP::Reponse to support HTTP/2 streams along with HTTP/1
# connections.
class HTTP::Server::Response
  @io : IO?                # HTTP/1
  @stream : HTTP2::Stream? # HTTP/2

  # :nodoc:
  def initialize(io : IO, @version = "HTTP/1.1")
    @io = io
    @headers = Headers.new
    @status_code = 200
    @wrote_headers = false
    @upgraded = false
    @output = output = @original_output = Output.new(io)
    output.response = self
  end

  # :nodoc:
  def initialize(stream : HTTP2::Stream, @version = "HTTP/2.0")
    @stream = stream
    @headers = Headers.new
    @status_code = 200
    @wrote_headers = false
    @upgraded = false
    @output = output = @original_output = StreamOutput.new(stream)
    output.response = self
  end

  def http1?
    @stream.nil?
  end

  def http2?
    @io.nil?
  end

  # NOTE: HTTP/2 connections can't be upgraded.
  def upgrade(upgrade = nil, @status_code = 101)
    if io = @io
      @upgraded = true
      headers["Connection"] = "Upgrade"
      headers["Upgrade"] = upgrade if upgrade
      write_headers
      flush
      yield io
    else
      raise "unexpected connection upgrade for #{@version}"
    end
  end

  protected def write_headers
    if io = @io
      # HTTP/1
      status_message = HTTP.default_status_message_for(@status_code)
      io << @version << " " << @status_code << " " << status_message << "\r\n"
      headers.each do |name, values|
        values.each do |value|
          io << name << ": " << value << "\r\n"
        end
      end
      io << "\r\n"
    else
      # HTTP/2
      raise "unexpected call to write_headers for #{@version}"
    end
    @wrote_headers = true
  end

  # :nodoc:
  # TODO: cap IO buffer to connection's max_frame_size setting (e.g. 16KB)
  class StreamOutput
    include IO::Buffered

    property! response : Response

    def initialize(@stream : HTTP2::Stream)
      @in_buffer_rem = Slice.new(Pointer(UInt8).null, 0)
      @out_count = 0
      @sync = false
      @flush_on_newline = false
      @wrote_headers = false
    end

    def reset
      raise "can't reset HTTP/2 response"
    end

    private def unbuffered_read(slice : Slice(UInt8))
      raise "can't read from HTTP::Server::Response"
    end

    private def unbuffered_write(slice : Slice(UInt8))
      ensure_headers_written
      @stream.send_data(slice)
    end

    def close
      unless @wrote_headers || @out_count == 0
        response.content_length = @out_count
      end
      ensure_headers_written
      super
    end

    private def ensure_headers_written
      unless @wrote_headers
        response.headers[":status"] = response.status_code.to_s

        if response.has_cookies?
          response.cookies.add_response_headers(response.headers)
        end

        flags = @out_count == 0 ? HTTP2::Frame::Flags::END_STREAM : HTTP2::Frame::Flags::None
        @stream.send_headers(response.headers, flags)
      end
      @wrote_headers = true
    end

    private def unbuffered_close
      @stream.send_data(Slice(UInt8).new(0), HTTP2::Frame::Flags::END_STREAM)
    end

    private def unbuffered_rewind
      raise "can't rewind to HTTP::Server::Response"
    end

    private def unbuffered_flush
    end
  end
end
