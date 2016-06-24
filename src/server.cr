require "openssl" ifdef !without_openssl
require "base64"
require "socket"
require "http/common"
require "http/server/handler"
require "./connection"
require "./server/context"
require "./server/response"
#require "./io/hexdump"

# An HTTP server.
#
# A server is given a handler that receives an `HTTP::Server::Context` that holds
# the `HTTP::Request` to process and must in turn configure and write to an `HTTP::Server::Response`.
#
# The `HTTP::Server::Response` object has `status` and `headers` properties that can be
# configured before writing the response body. Once response output is written,
# changing the `status` and `headers` properties has no effect.
#
# The `HTTP::Server::Response` is also a write-only `IO`, so all `IO` methods are available
# in it.
#
# The handler given to a server can simply be a block that receives an `HTTP::Server::Context`,
# or it can be an `HTTP::Handler`. An `HTTP::Handler` has an optional `next` handler,
# so handlers can be chained. For example, an initial handler may handle exceptions
# in a subsequent handler and return a 500 status code (see `HTTP::ErrorHandler`),
# the next handler might log the incoming request (see `HTTP::LogHandler`), and
# the final handler deals with routing and application logic.
#
# ### Simple Setup
#
# A handler is given with a block.
#
# ```
# require "http/server"
#
# server = HTTP::Server.new(8080) do |context|
#   context.response.content_type = "text/plain"
#   context.response.print "Hello world!"
# end
#
# puts "Listening on http://127.0.0.1:8080"
# server.listen
# ```
#
# ### With non-localhost bind address
#
# ```
# require "http/server"
#
# server = HTTP::Server.new("0.0.0.0", 8080) do |context|
#   context.response.content_type = "text/plain"
#   context.response.print "Hello world!"
# end
#
# puts "Listening on http://0.0.0.0:8080"
# server.listen
# ```
#
# ### Add handlers
#
# A series of handlers are chained.
#
# ```
# require "http/server"
#
# HTTP::Server.new("127.0.0.1", 8080, [
#   HTTP::ErrorHandler.new,
#   HTTP::LogHandler.new,
#   HTTP::DeflateHandler.new,
#   HTTP::StaticFileHandler.new("."),
# ]).listen
# ```
#
# ### Add handlers and block
#
# A series of handlers is chained, the last one being the given block.
#
# ```
# require "http/server"
#
# server = HTTP::Server.new("0.0.0.0", 8080,
#   [
#     HTTP::ErrorHandler.new,
#     HTTP::LogHandler.new,
#   ]) do |context|
#   context.response.content_type = "text/plain"
#   context.response.print "Hello world!"
# end
#
# server.listen
# ```
class HTTP::Server
  ifdef !without_openssl
    property tls : OpenSSL::SSL::Context::Server?

    # Returns the default OpenSSL context, suitable for HTTP2, with ALPN
    # protocol negotiation.
    def self.default_tls_context : OpenSSL::SSL::Context::Server
      tls_context = OpenSSL::SSL::Context::Server.new
      tls_context.alpn_protocol = "h2"
      tls_context
    end
  end

  @wants_close = false

  def self.new(port, &handler : Context ->)
    new("127.0.0.1", port, &handler)
  end

  def self.new(port, handlers : Array(HTTP::Handler), &handler : Context ->)
    new("127.0.0.1", port, handlers, &handler)
  end

  def self.new(port, handlers : Array(HTTP::Handler))
    new("127.0.0.1", port, handlers)
  end

  def self.new(port, handler)
    new("127.0.0.1", port, handler)
  end

  def initialize(@host : String, @port : Int32, &@handler : Context ->)
  end

  def initialize(@host : String, @port : Int32, handlers : Array(HTTP::Handler), &handler : Context ->)
    @handler = HTTP::Server.build_middleware handlers, handler
  end

  def initialize(@host : String, @port : Int32, handlers : Array(HTTP::Handler))
    @handler = HTTP::Server.build_middleware handlers
  end

  def initialize(@host : String, @port : Int32, @handler : HTTP::Handler | HTTP::Handler::Proc)
  end

  def port
    if server = @server
      server.local_address.port.to_i
    else
      @port
    end
  end

  def bind
    @server ||= TCPServer.new(@host, @port)
  end

  def listen
    server = bind
    until @wants_close
      spawn handle_client(server.accept?)
    end
  end

  def close
    @wants_close = true
    if server = @server
      server.close
      @server = nil
    end
  end

  @logger : Logger?

  def logger
    @logger ||= Logger.new(STDOUT).tap do |logger|
      logger.level = Logger::Severity::DEBUG
      logger.formatter = Logger::Formatter.new do |s, d, p, message, io|
        io << message
      end
    end
  end

  private def handle_client(io)
    # nil means the server was closed
    return unless io

    io.sync = false

    alpn = nil
    ifdef !without_openssl
      if tls = @tls
        io = OpenSSL::SSL::Socket::Server.new(io, tls, sync_close: true)
        {% if LibSSL::OPENSSL_102 %}
        alpn = io.alpn_protocol
        {% end %}
      end
    end

    #io = IO::Hexdump.new(io, logger, write: false)

    must_close = true
    response = Response.new(io)

    begin
      until @wants_close
        if alpn == "h2"
          handle_http2_client(io)
          return
        end

        begin
          request = HTTP::Request.from_io(io)
        rescue e
          STDERR.puts "Bug: Unhandled exception while parsing request"
          e.inspect_with_backtrace(STDERR)
        end

        unless request
          response.respond_with_error("Bad Request", 400)
          response.close
          return
        end

        if request.method == "PRI" && request.resource == "*" && request.version == "HTTP/2.0"
          handle_http2_client(io)
          return
        end

        response.version = request.version
        response.reset

        if settings = http2_upgrade?(request)
          response.upgrade("h2c") do |io|
            io.flush
            handle_http2_client(io, request, Base64.decode(settings))
          end
          return
        end

        response.headers["Connection"] = "keep-alive" if request.keep_alive?
        context = Context.new(request, response)

        @handler.call(context)

        if response.upgraded?
          must_close = false
          return
        end

        response.output.close
        io.flush

        break unless request.keep_alive?
      end
    rescue e
      response.respond_with_error
      response.close
      STDERR.puts "Unhandled exception while computing response, make sure to catch all your exceptions"
      e.inspect_with_backtrace(STDERR)
    ensure
      io.close if must_close
    end
  end

  private def http2_upgrade?(request)
    return unless request.headers["upgrade"]? == "h2c"
    return unless settings = request.headers.get?("http2-settings")
    settings.first if settings.size == 1
  end

  private def handle_http2_client(io, request = nil, raw_settings = nil)
    connection = HTTP2::Connection.new(io, logger: logger)
    logger.debug { "Connected" }

    if raw_settings
      connection.remote_settings.parse(raw_settings) do |setting, value|
        logger.debug { "  #{setting}=#{value}" }
      end
    end

    connection.read_client_preface(truncated: !@tls && request == nil)
    connection.write_settings

    frame = connection.receive

    unless frame.try(&.type) == HTTP2::Frame::Type::SETTINGS
      connection.close(HTTP2::Error.protocol_error("EXPECTED settings frame"))
      return
    end

    if request.is_a?(HTTP::Request)
      stream = connection.streams.find(1)

      # FIXME: the cast is required for Crystal to compile
      spawn handle_http2_request(stream, request.as(HTTP::Request))
    end

    loop do
      next unless frame = connection.receive

      case frame.type
      when HTTP2::Frame::Type::HEADERS
        # don't dispatch twice
        next if frame.stream.trailing_headers?

        headers = validate_http2_headers(frame.stream.headers)
        req = HTTP::Request.new(headers[":method"], headers[":path"], headers, version: "HTTP/2.0")
        spawn handle_http2_request(frame.stream, req)

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
      begin
        connection.close(error: err) unless connection.closed?
      rescue HTTP2::Error
        # FIXME: impossible, but required because the *outer rescue* won't stop
        #        the exception from bubbling up sometimes. To reproduce:
        #
        #        h2spec -s 5.1.2
      end
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

  protected def validate_http2_headers(headers)
    # TODO: move the following validations to HPACK decoder (add mecanism to validate headers as they are decoded)
    regular = false

    headers.each do |name, value|
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
      %w(:scheme :path).each do |name|
        unless headers.get?(name).try(&.size) == 1
          raise HTTP2::Error.protocol_error("INVALID #{name} pseudo-header")
        end
      end
    end

    headers
  end

  # Builds all handlers as the middleware for HTTP::Server.
  def self.build_middleware(handlers, last_handler : Context -> = nil)
    raise ArgumentError.new "You must specify at least one HTTP Handler." if handlers.empty?
    0.upto(handlers.size - 2) { |i| handlers[i].next = handlers[i + 1] }
    handlers.last.next = last_handler if last_handler
    handlers.first
  end
end
