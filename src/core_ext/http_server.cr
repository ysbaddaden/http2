require "base64"
require "compress/deflate"
require "compress/gzip"
require "http/server"
require "./http_request"
require "./http_server_response"
require "../connection"
require "../server/http1"

class HTTP::Server
  {% unless flag?(:without_openssl) %}
    def bind_tls(host : String, port : Int32, context : OpenSSL::SSL::Context::Server, reuse_port : Bool = false) : Socket::IPAddress
      context.alpn_protocol = "h2"
      previous_def(host, port, context, reuse_port)
    end
  {% end %}

  # TODO: respect max_request_line_size
  property max_request_line_size = HTTP::MAX_REQUEST_LINE_SIZE

  # TODO: respect max_headers_size
  property max_headers_size = HTTP::MAX_HEADERS_SIZE

  @processor = uninitialized RequestProcessor

  def initialize(@handler : HTTP::Handler | HTTP::Handler::HandlerProc)
  end

  private def handle_client(io : IO)
    if io.is_a?(IO::Buffered)
      io.sync = false
    end

    scheme = "http"

    {% unless flag?(:without_openssl) %}
      if io.is_a?(OpenSSL::SSL::Socket::Server)
        begin
          io.accept
        rescue ex
          Log.debug(exception: ex) { "Error during SSL handshake" }
          return
        end

        if io.alpn_protocol == "h2"
          handle_http2_connection(io, alpn: "h2")
          return
        end

        scheme = "https"
      end
    {% end %}

    connection = HTTP::Connection.new(io)

    {% begin %}
    begin
      return unless request_line = connection.read_request_line
      method, path = request_line

      case connection.version
      when "HTTP/1.1", "HTTP/1.0"
        handle_http1_connection(connection, scheme, method, path)
      when "HTTP/2.0"
        if method == "PRI" && path == "*"
          handle_http2_connection(io)
        else
          bad_request(io)
        end
      else
        # protocol error: merely close the connection
      end
    rescue IO::EOFError | IO::Error {% unless flag?(:without_openssl) %} | OpenSSL::SSL::Error {% end %}
      # silence
    ensure
      begin
        {% if flag?(:h2spec) %}
          # FIXME: works around a bug in h2spec where the GOAWAY frame may
          # sometimes not be read *before* it notices that the IO is closed.
          sleep(100.milliseconds)
        {% end %}
        io.close
      rescue IO::EOFError | IO::Error {% unless flag?(:without_openssl) %} | OpenSSL::SSL::Error {% end %}
        # silence
      end
    end
    {% end %}
  end

  private def handle_http1_connection(connection, scheme, method, path)
    loop do
      headers = HTTP::Headers{
        ":method" => method,
        ":path"   => path,
        ":scheme" => scheme,
      }
      unless connection.read_headers(headers)
        bad_request(connection.io)
        break
      end

      content = connection.content(headers)
      body = decode_body(content, headers)
      request = HTTP::Request.new(headers, body, connection.version)

      if settings = http2_upgrade_request?(headers)
        connection.http2_upgrade("h2c")
        handle_http2_connection(connection.io, request, Base64.decode(settings), alpn: "h2c")
        break
      end

      response = HTTP::Server::Response.new(connection)
      response.headers["connection"] = "keep-alive" if request.keep_alive?

      context = HTTP::Server::Context.new(request, response)
      handle_request(context)

      break if response.headers["connection"] == "Upgrade"
      break unless request.keep_alive?

      case content
      when HTTP::FixedLengthContent
        break if content.read_remaining > 0
      when HTTP::ChunkedContent
        break unless content.closed?
      end
    end
  end

  private def http2_upgrade_request?(headers)
    return unless headers["upgrade"]? == "h2c"
    return unless settings = headers.get?("http2-settings")
    settings.first if settings.size == 1
  end

  private def handle_http2_connection(io, request = nil, settings = nil, alpn = nil) : Nil
    connection = HTTP2::Connection.new(io, HTTP2::Connection::Type::SERVER)

    if settings
      # HTTP/1 => HTTP/2 upgrade: we got settings
      connection.remote_settings.parse(settings) do |setting, value|
        Log.trace { "  #{setting}=#{value}" }
      end
    end

    connection.read_client_preface(truncated: alpn.nil?)
    connection.write_settings

    frame = connection.receive
    unless frame.try(&.type) == HTTP2::Frame::Type::SETTINGS
      raise HTTP2::Error.protocol_error("Expected SETTINGS frame")
    end

    if request
      # HTTP/1 => HTTP/2 upgrade: reply to HTTP/1 request on stream #1 of HTTP/2
      stream = connection.streams.find(1)
      context = context_for(stream, request)
      spawn handle_request(context.as(Context))
    end

    loop do
      unless frame = connection.receive
        next
      end

      case frame.type
      when HTTP2::Frame::Type::HEADERS
        # don't dispatch twice
        next if frame.stream.trailing_headers?
        context = context_for(frame.stream)
        spawn handle_request(context.as(Context))
      when HTTP2::Frame::Type::PUSH_PROMISE
        raise HTTP2::Error.protocol_error("Unexpected PUSH_PROMISE frame")
      when HTTP2::Frame::Type::GOAWAY
        break
      end
    end
  rescue ex : HTTP2::Error
    if connection
      connection.close(error: ex) unless connection.closed?
    end
  rescue ex : HTTP::Server::ClientError | IO::Error | IO::EOFError
    # silence
  ensure
    if connection
      connection.close unless connection.closed?
    end
  end

  private def context_for(stream : HTTP2::Stream, request = nil) : Context
    unless request
      headers = stream.headers
      body = decode_body(stream.data, headers) if stream.state.open?
      request = HTTP::Request.new(headers, body, "HTTP/2.0")
    end
    response = HTTP::Server::Response.new(stream)
    HTTP::Server::Context.new(request, response)
  end

  private def handle_request(context : Context)
    @handler.call(context)
  ensure
    begin
      context.response.close
      # context.request.close
    rescue ex : HTTP2::Error | IO::Error | IO::EOFError
      # silence
    end
  end

  private def decode_body(body, headers)
    return unless body

    {% if flag?(:without_zlib) %}
      case headers["content-encoding"]?
      when "gzip", "deflate"
        raise "Can't decompress because `-D without_zlib` was passed at compile time"
      end
    {% else %}
      case headers["content-encoding"]?
      when "gzip"
        body = Compress::Gzip::Reader.new(body, sync_close: true)
        headers.delete("content-encoding")
        headers.delete("content-length")
      when "deflate"
        body = Compress::Deflate::Reader.new(body, sync_close: true)
        headers.delete("content-encoding")
        headers.delete("content-length")
      end
    {% end %}

    check_content_type_charset(body, headers)

    body
  end

  private def check_content_type_charset(body, headers)
    content_type = headers["content-type"]?
    return unless content_type

    mime_type = MIME::MediaType.parse?(content_type)
    return unless mime_type

    charset = mime_type["charset"]?
    return unless charset

    body.set_encoding(charset, invalid: :skip)
  end

  private def bad_request(io) : Nil
    io << "HTTP/1.1 400 BAD REQUEST\r\nConnection: close\r\n\r\n"
  end

end
