require "base64"
#require "io/hexdump"
require "./context"
require "./response"

# Overloads HTTP::RequestProcessor to support HTTP/2 connections transparently
# along with HTTP/1 connections.
class HTTP::Server::RequestProcessor
  def process(io, alpn, logger)
    must_close = true

    #io = IO::Hexdump.new(io, read: true)

    if alpn == "h2"
      handle_http2_client(io, alpn: alpn, logger: logger)
      return
    end

    response = Response.new(io)

    begin
      until @wants_close
        request = Request.from_io(io)
        break unless request

        if request.is_a?(HTTP::Request::BadRequest)
          response.respond_with_error("Bad Request", 400)
          response.close
          return
        end

        if request.method == "PRI" && request.resource == "*" && request.version == "HTTP/2.0"
          handle_http2_client(io, logger: logger)
          return
        end

        response.version = request.version
        response.reset

        if settings = http2_upgrade?(request)
          response.upgrade("h2c") do |io|
            io.flush
            handle_http2_client(io, request, Base64.decode(settings), alpn: "h2c", logger: logger)
          end
          return
        end

        if request.keep_alive?
          response.headers["Connection"] = "keep-alive"
        end
        context = Context.new(request, response)

        begin
          @handler.call(context)
        rescue ex
          response.respond_with_error
          response.close
          logger.error("Unhandled exception on HTTP::Handler: #{ex.inspect_with_backtrace}")
          return
        end

        if response.upgraded?
          must_close = false
          return
        end

        response.output.close
        io.flush

        break unless request.keep_alive?

        # Skip request body in case the handler
        # didn't read it all, for the next request
        request.body.try(&.close)
      end

    rescue ex : Errno
      # FIXME: calling with curl results in EPIPE (certainly related to
      #        SSL::Error below)
      raise ex unless ex.errno == Errno::EPIPE

    rescue ex : OpenSSL::SSL::Error
      # FIXME: calling with curl results in "SSL_read: ZERO_RETURN" exception
      #        (certainly related to EPIPE above)
      raise ex unless ex.message.try(&.includes?("ZERO_RETURN"))

    ensure
      io.close if must_close
    end
  end

  private def http2_upgrade?(request)
    return unless request.headers["upgrade"]? == "h2c"
    return unless settings = request.headers.get?("http2-settings")
    settings.first if settings.size == 1
  end

  private def handle_http2_client(io, request = nil, raw_settings = nil, alpn = nil, logger : Logger = nil)
    connection = HTTP2::Connection.new(io, logger: logger)
    logger.debug { "Connected" }

    if raw_settings
      connection.remote_settings.parse(raw_settings) do |setting, value|
        logger.debug { "  #{setting}=#{value}" }
      end
    end

    # in case of a direct HTTP/2 request without prior TLS ALPN protocol
    # negotiation or HTTP Upgrade, we already started to read the HTTP/2
    # preface
    connection.read_client_preface(truncated: alpn.nil?)
    connection.write_settings

    frame = connection.receive
    unless frame.try(&.type) == HTTP2::Frame::Type::SETTINGS
      connection.close(HTTP2::Error.protocol_error("EXPECTED settings frame"))
      return
    end

    if request
      # HTTP/1 to HTTP/2 upgrade: we must process the initial HTTP/1 request
      # but send a HTTP/2 response on stream 1
      stream = connection.streams.find(1)

      # FIXME: the cast is required for Crystal to compile
      spawn handle_http2_request(stream, request.as(Request))
    end

    loop do
      unless frame = connection.receive
        next
      end

      case frame.type
      when HTTP2::Frame::Type::HEADERS
        # don't dispatch twice
        next if frame.stream.trailing_headers?

        headers = validate_http2_headers(frame.stream.headers)
        request = Request.new(headers[":method"], headers[":path"], headers, version: "HTTP/2.0")
        spawn handle_http2_request(frame.stream, request)

      when HTTP2::Frame::Type::PUSH_PROMISE
        raise HTTP2::Error.protocol_error("UNEXPECTED push promise frame")

      when HTTP2::Frame::Type::GOAWAY
        break
      end
    end

  rescue err : HTTP2::ClientError
    logger.debug { "#{err.code}: #{err.message}" }

  rescue err : HTTP2::Error
    if connection
      connection.close(error: err) unless connection.closed?
    end
    logger.debug { "#{err.code}: #{err.message}" }

  ensure
    if connection
      connection.close unless connection.closed?
    end
    logger.debug { "Disconnected" }
  end

  protected def handle_http2_request(stream, request)
    response = Response.new(stream, request.version)
    context = Context.new(request, response, stream)
    @handler.call(context)
    response.close
  ensure
    stream.data.close
  end

  # TODO: move the following validations to HPACK decoder, using a mecanism
  #       to validate headers as they are decoded.
  protected def validate_http2_headers(headers)
    regular = false

    headers.each do |name, value|
      # special colon (:) headers MUST come before the regular headers
      regular ||= !name.starts_with?(':')

      if (name.starts_with?(':') && (regular || !HTTP2::REQUEST_PSEUDO_HEADERS.includes?(name))) || ("A" .. "Z").covers?(name)
        raise HTTP2::Error.protocol_error("MALFORMED #{name} header")
      end
      if name == "connection"
        raise HTTP2::Error.protocol_error("MALFORMED #{name} header")
      end
      if name == "te" && value != "trailers"
        raise HTTP2::Error.protocol_error("MALFORMED #{name} header")
      end
    end

    unless headers.get?(":method").try(&.size) == 1
      raise HTTP2::Error.protocol_error("INVALID :method pseudo-header")
    end

    unless headers[":method"] == "CONNECT"
      unless headers.get?(":scheme").try(&.size) == 1
        raise HTTP2::Error.protocol_error("INVALID :scheme pseudo-header")
      end

      paths = headers.get?(":path")
      unless paths.try(&.size) == 1 && !paths.try(&.first.empty?)
        raise HTTP2::Error.protocol_error("INVALID :path pseudo-header")
      end
    end

    headers
  end
end
