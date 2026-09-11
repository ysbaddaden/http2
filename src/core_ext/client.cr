require "http/client"

class HTTP::Client
  getter? closed : Atomic(Bool).new(false)

  # TODO: max_concurrent_streams to configure SETTINGS_MAX_CONCURRENT_STREAMS
  # TODO: max_header_list_size to configure SETTINGS_MAX_HEADER_LIST_SIZE
  # TODO: ...

  @protocol : String?
  @mutex = Mutex.new

  # Identical to the original constructor with the addition of the *protocol*
  # argument that can be `h1` for HTTP/1, `h2` for HTTP/2 or `h2c` (HTTP/1
  # upgrade to HTTP/2).
  def initialize(host : String, port = nil, tls : TLSContext = nil, @protocol : String? = nil)
    case protocol
    when "h2", nil
      tls.alpn_protocol = "h2" if tls
    when "h2c"
      raise ArgumentError.new("Invalid ALPN protocol h2c (HTTP/1 to HTTP/2 upgrade)") if tls
    else
      raise ArgumentError.new("Unsupported ALPN protocol #{protocol}")
    end
    previous_def(host, port, tls)
  end

  def initialize(@io : IO, @host = "", @port = 80, @protocol : String? = nil)
    @reconnect = false
  end

  def authority : String
    host_header
  end

  def scheme : String
    tls ? "https" : "http"
  end

  private def pending_requests
    @pending_requests ||= Hash(Stream, Fiber).new
  end

  private def exec_internal(request)
    # implicit_compression = implicit_compression?(request)
    # begin
    #   response = exec_internal_single(request, implicit_compression: implicit_compression)
    # rescue exc : IO::Error
    #   raise exc if @io.nil? # do not retry if client was closed
    #   response = nil
    # end
    # return handle_response(response) if response

    # # Server probably closed the connection, so retry once
    # close
    # request.body.try &.rewind
    # response = exec_internal_single(request, implicit_compression: implicit_compression)
    # return handle_response(response) if response

    # raise IO::EOFError.new("Unexpected end of http response")
    raise NotImplementedError.new("HTTP::Client#exec_internal_single()")
  end

  private def exec_internal_single(request, implicit_compression = false)
    # send_request(request)
    # HTTP::Client::Response.from_io?(io, ignore_body: request.ignore_body?, decompress: implicit_compression)
    raise NotImplementedError.new("HTTP::Client#exec_internal_single()")
  end

  private def handle_response(response)
    # close unless response.keep_alive?
    # response
    raise NotImplementedError.new("HTTP::Client#handle_response()")
  end

  private def exec_internal(request, &block : Response -> T) : T forall T
    # implicit_compression = implicit_compression?(request)
    # exec_internal_single(request, ignore_io_error: true, implicit_compression: implicit_compression) do |response|
    #   if response
    #     return handle_response(response) { yield response }
    #   end
    # end

    # # Server probably closed the connection, so retry once
    # close
    # request.body.try &.rewind
    # exec_internal_single(request, implicit_compression: implicit_compression) do |response|
    #   if response
    #     return handle_response(response) { yield response }
    #   end
    # end
    # raise IO::EOFError.new("Unexpected end of http response")
    raise NotImplementedError.new("HTTP::Client#exec_internal(&)")
  end

  private def exec_internal_single(request, ignore_io_error = false, implicit_compression = false, &)
    # begin
    #   send_request(request)
    # rescue ex : IO::Error
    #   return yield nil if ignore_io_error && !@io.nil? # ignore_io_error only if client was not closed
    #   raise ex
    # end
    # HTTP::Client::Response.from_io?(io, ignore_body: request.ignore_body?, decompress: implicit_compression) do |response|
    #   yield response
    # end
    raise NotImplementedError.new("HTTP::Client#exec_internal_internal(&)")
  end

  private def handle_response(response, &)
    # yield
    raise NotImplementedError.new("HTTP::Client#handle_response(&)")
  ensure
    # response.body_io?.try &.close
    # close unless response.keep_alive?
  end

  private def send_request(request)
    # set_defaults request
    # run_before_request_callbacks(request)
    # request.to_io(io)
    # io.flush
    raise NotImplementedError.new("HTTP::Client#send_request()")
  end

  def close : Nil
    @connection.try(&.close)
  rescue IO::Error
  end

  def closed? : Bool
    @connection.try(&.closed?) || false
  end

  private def connection : HTTP::Connection || HTTP2::Connection
    @connection ||= connect
  end

  private def connect
    if tls
      case @protocol
      when "h1"
        http1_connect
      else
        http2_connect
      end
    else
      case @protocol
      when "h2"
        http2_connect
      when "h2c"
        # todo: first request must try to upgrade
        http1_connect
      else
        http1_connect
      end
    end
  rescue HTTP2::Error
    begin
      connection.close(error)
    ensure
      io.close
    end
  end

  private def http1_connect : HTTP::Connection
    raise NotImplementedError.new("HTTP::Client#http1_connect")
  end

  private def http2_connect : HTTP2::Connection
    connection = HTTP2::Connection.new(io, HTTP2::Connection::Type::CLIENT)
    connection.write_client_preface
    connection.write_settings

    frame = connection.receive
    unless frame.try(&.type) == HTTP2::Frame::Type::SETTINGS
      raise HTTP2::Error.protocol_error("Expected SETTINGS frame")
    end

    # OPTIMIZE: spawning a fiber sounds overkill, especially for one-shot requests
    spawn receive_http2_frames(connection)

    connection
  end

  private def receive_http2_frames(connection)
    loop do
      unless frame = connection.receive
        next # unknown frame
      end

      case frame.type
      when Frame::Type::HEADERS
        @mutex.synchronize do
          pending_requests.delete(frame.stream).try(&.resume)
        end
      when Frame::Type::PUSH_PROMISE
        frame.stream.close
      when Frame::Type::GOAWAY
        break
      end
    end
  end

  private def io
    io = @io
    return io if io

    raise "This HTTP::Client cannot be reconnected" unless @reconnect

    hostname = @host.starts_with?('[') && @host.ends_with?(']') ? @host[1..-2] : @host
    io = TCPSocket.new hostname, @port, @dns_timeout, @connect_timeout
    io.read_timeout = @read_timeout if @read_timeout
    io.write_timeout = @write_timeout if @write_timeout
    io.sync = false

    {% if !flag?(:without_openssl) %}
      if tls = @tls
        tcp_socket = io
        begin
          io = OpenSSL::SSL::Socket::Client.new(tcp_socket, context: tls, sync_close: true, hostname: @host.rchop('.'))
        rescue exc
          # don't leak the TCP socket when the SSL connection failed
          tcp_socket.close
          raise exc
        end
      end
    {% end %}

    @io = io
  end
end
