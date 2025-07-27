require "http/server/response"

class HTTP::Server
  class Response
    # :nodoc:
    class Output
      @io = uninitialized IO
      @chunked = false
      @closed = false

      getter? sent_headers : Bool = false

      def upgrade(protocol : String?, &)
        raise NotImplementedError.new("#{self.class.name}#upgrade")
      end

      def send_headers(description : String?) : Nil
        raise NotImplementedError.new("#{self.class.name}#send_headers")
      end
    end
  end
end

# :nodoc:
class HTTP::Output < HTTP::Server::Response::Output
  def initialize(@connection : Connection, @headers : HTTP::Headers)
  end

  def version=(version : String)
    @connection.version = version
  end

  def reset : Nil
    raise NotImplementedError.new("HTTP::Output#reset")
  end

  def send_headers(description : String?) : Nil
    @sent_headers = true

    if @headers["transfer-encoding"]? == "chunked"
      @chunked = true
    elsif @connection.version == "HTTP/1.1" && !@headers.has_key?("content-length")
      @headers["transfer-encoding"] = "chunked"
      @chunked = true
    end

    @connection.send_headers(@headers, description)
  end

  def upgrade(protocol : String?, &)
    if sent_headers?
      raise ArgumentError.new("Can't upgrade HTTP/1 connection: headers have already been sent")
    end

    @headers[":status"] = "101"
    @headers["connection"] = "Upgrade"
    @headers["upgrade"] = protocol if protocol

    @connection.send_headers(@headers)
    @connection.flush

    yield @connection.io
  end

  def close : Nil
    return if closed?

    unless sent_headers?
      status = HTTP::Status.new(@headers[":status"].to_i)

      # determine if the `content-length` header should be added.
      # see https://tools.ietf.org/html/rfc7230#section-3.3.2.
      if !@headers.has_key?("transfer-encoding") &&
          !@headers.has_key?("content-length") &&
          !(status.not_modified? || status.no_content? || status.informational?)
        @headers["content-length"] = @out_count.to_s
      end
    end

    # can't call super because it would call Output#close, we inline
    # IO::Buffered#close instead
    flush if @out_count > 0
  ensure
    unbuffered_close
  end

  def unbuffered_write(slice : Bytes) : Nil
    return if slice.empty?

    @connection.send_data(slice, @chunked)
    slice.size
  rescue ex : IO::Error
    unbuffered_close
    raise HTTP::Server::ClientError.new("Error while writing data to the client", ex)
  end

  def unbuffered_flush : Nil
    @connection.flush
  end

  def unbuffered_close : Nil
    @closed = true
    @connection.send_data("", @chunked) if @chunked
    @connection.flush
  end
end

# :nodoc:
class HTTP2::Output < HTTP::Server::Response::Output
  def initialize(@stream : HTTP2::Stream, @headers : HTTP::Headers)
  end

  def reset : Nil
    raise NotImplementedError.new("Can't reset HTTP/2 stream")
  end

  def send_headers(description : String? = nil) : Nil
    @sent_headers = true
    @stream.send_headers(@headers)
  end

  def upgrade(protocol : String?, &block)
    raise NotImplementedError.new("Can't upgrade HTTP/2 stream")
  end

  def close : Nil
    return if closed?

    unless sent_headers?
      status = HTTP::Status.new(@headers[":status"].to_i)

      # determine if the `content-length` header should be added.
      # see https://tools.ietf.org/html/rfc7230#section-3.3.2.
      if !@headers.has_key?("transfer-encoding") &&
          !@headers.has_key?("content-length") &&
          !(status.not_modified? || status.no_content? || status.informational?)
        @headers["content-length"] = @out_count.to_s
      end
    end

    # can't call super because it would call Output#close, we inline
    # IO::Buffered#close instead
    flush if @out_count > 0
  ensure
    unbuffered_close
  end

  def unbuffered_write(slice : Bytes) : Nil
    return if slice.empty?

    @stream.send_data(slice)
    slice.size
  rescue ex : IO::Error
    unbuffered_close
    raise HTTP::Server::ClientError.new("Error while writing data to the client", ex)
  end

  def unbuffered_flush : Nil
  end

  def unbuffered_close : Nil
    @closed = true
    @stream.send_data("", flags: Frame::Flags::END_STREAM)
    @stream.send_rst_stream(HTTP2::Error::Code::NO_ERROR)
  end
end

class HTTP::Server
  class Response < IO
    @original_output : Output

    # needed because of monkey-patch
    @io = uninitialized IO
    @status = uninitialized HTTP::Status
    @wrote_headers = uninitialized Bool

    # :nodoc:
    def initialize(connection : HTTP::Connection)
      @headers = HTTP::Headers.new
      @headers[":status"] ||= "200"
      @version = connection.version
      output = HTTP::Output.new(connection, @headers)
      @original_output = output
      @output = output.as(IO)
    end

    # :nodoc:
    def initialize(stream : HTTP2::Stream)
      @headers = HTTP::Headers.new
      @headers[":status"] ||= "200"
      @version = "HTTP/2.0"
      output = HTTP2::Output.new(stream, @headers)
      @original_output = output
      @output = output.as(IO)
    end

    # :nodoc:
    def reset : Nil
      raise NotImplementedError.new("HTTP::Server::Response#reset")
    end

    def version=(version : String)
      check_headers

      if (output = @original_output).is_a?(HTTP::Output)
        output.@connection.version = version
      end
      @version = version
    end

    def status : HTTP::Status
      HTTP::Status.new(status_code)
    end

    def status=(status : HTTP::Status)
      check_headers
      @headers[":status"] = status.to_i.to_s
      status
    end

    def status_code : Int32
      @headers[":status"].to_i
    end

    def status_code=(status_code : Int32)
      self.status = HTTP::Status.new(status_code)
      status_code
    end

    def upgrade(protocol : String? = nil, &) : Nil
      @original_output.upgrade(protocol) { |io| yield io }
    end

    def write(slice : Bytes) : Nil
      # NOTE: this deviates from `super` that won't send headers when slice is
      # empty (it immediately returns)
      write_headers unless @original_output.sent_headers?
      @output.write(slice) unless slice.empty?
    end

    def flush : Nil
      # NOTE: this deviates from `super` that won't send headers when the buffer
      # is empty (nothing to flush => doesn't write)
      write_headers unless @original_output.sent_headers?
      @output.flush
    end

    def close : Nil
      return if closed?
      write_headers unless @original_output.sent_headers?

      flush
      @output.close
    end

    def respond_with_status(status : HTTP::Status, message : String? = nil) : Nil
      check_headers

      @headers.clear
      self.status = status
      self.content_type = "text/plain"
      @original_output.send_headers(message)

      @output = @original_output
      @output.close
    end

    private def check_headers
      raise IO::Error.new "Closed stream" if @original_output.closed?
      raise IO::Error.new("Headers already sent") if @original_output.sent_headers?
    end

    protected def write_headers : Nil
      if cookies = @cookies
        cookies.add_response_headers(@headers)
      end
      @original_output.send_headers(@status_message)
    end
  end
end
