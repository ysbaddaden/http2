require "base64"
require "flate"
require "gzip"
#require "io/hexdump"
require "logger"
require "openssl"
require "./connection"
require "./server/handler"
require "./server/http1"
require "./server/context"

module HTTP2
  class Server
    @handler : Handler?
    @logger : Logger
    @ssl_context : OpenSSL::SSL::Context::Server?

    def initialize(host : String, port : Int32, ssl_context = nil, logger = nil)
      @server = TCPServer.new(host, port)
      @logger = logger || Logger::Dummy.new

      if ssl_context
        ssl_context.alpn_protocol = "h2"
        @ssl_context = ssl_context
      end
    end

    def listen(handlers : Array(Handler))
      raise ArgumentError.new("you must have at least one handler") if handlers.size == 0
      handlers.reduce { |a, b| a.next = b; b }
      @handler = handlers.first
      loop { spawn handle_socket(@server.accept) }
    end

    private def handle_socket(io : IO) : Nil
      must_close = true

      if ssl_context = @ssl_context
        io = OpenSSL::SSL::Socket::Server.new(io, ssl_context)

        if io.alpn_protocol == "h2"
          must_close = false
          return handle_http2_connection(io, alpn: "h2")
        end
      end

      # if ENV["HTTP_DUMP"]?
      #   io = IO::Hexdump.new(io, read: true)
      # end

      connection = HTTP1::Connection.new(io)

      loop do
        break unless request_line = connection.read_request_line
        method, path = request_line

        case connection.version
        when "HTTP/1.1", "HTTP/1.0"
          headers = HTTP::Headers{
            ":method" => method,
            ":path" => path,
          }
          unless connection.read_headers(headers)
            return bad_request(io)
          end

          body = decode_body(connection.content(headers), headers)
          request = Request.new(headers, body, connection.version)

          if settings = http2_upgrade?(headers)
            connection.upgrade("h2c")
            must_close = false
            return handle_http2_connection(connection.io, request, Base64.decode(settings), alpn: "h2c")
          end

          response = Response.new(connection)
          response.headers["connection"] = "keep-alive" if request.keep_alive?

          context = Context.new(request, response)
          handle_request(context)

          if response.upgraded?
            must_close = false
            break
          end

          unless request.keep_alive? && response.headers["connection"] == "keep-alive"
            break
          end
        when "HTTP/2.0"
          if method == "PRI" && path == "*"
            must_close = false
            return handle_http2_connection(io)
          else
            return bad_request(io)
          end
        else
          return bad_request(io)
        end
      end
    ensure
      begin
        io.close if must_close
      #rescue ex : Errno
      #  raise ex unless {Errno::EPIPE, Errno::ECONNRESET}.includes?(ex.errno)
      rescue IO::EOFError | IO::Error
      end
    end

    private def decode_body(body, headers)
      return unless body

      case headers["Content-Encoding"]?
      when "gzip"
        body = Gzip::Reader.new(body, sync_close: true)
      when "deflate"
        body = Flate::Reader.new(body, sync_close: true)
      end

      check_content_type_charset(body, headers)

      body
    end

    private def check_content_type_charset(body, headers)
      content_type = headers["Content-Type"]?
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

    private def handle_http1_connection(connection, method, path)
    end

    private def http2_upgrade?(headers)
      return unless headers["upgrade"]? == "h2c"
      return unless settings = headers.get?("http2-settings")
      settings.first if settings.size == 1
    end

    private def handle_http2_connection(io, request = nil, settings = nil, alpn = nil) : Nil
      connection = Connection.new(io, Connection::Type::SERVER, @logger)

      if settings
        # HTTP/1 => HTTP/2 upgrade: we got settings
        connection.remote_settings.parse(settings) do |setting, value|
          @logger.debug { "  #{setting}=#{value}" }
        end
      end

      connection.read_client_preface(truncated: alpn.nil?)
      connection.write_settings

      frame = connection.receive
      unless frame.try(&.type) == Frame::Type::SETTINGS
        raise Error.protocol_error("Expected SETTINGS frame")
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
        when Frame::Type::HEADERS
          # don't dispatch twice
          next if frame.stream.trailing_headers?
          context = context_for(frame.stream)
          spawn handle_request(context.as(Context))
        when Frame::Type::PUSH_PROMISE
          raise Error.protocol_error("Unexpected PUSH_PROMISE frame")
        when Frame::Type::GOAWAY
          break
        end
      end
    rescue ex : HTTP2::ClientError
      @logger.debug { "RECV: #{ex.code}: #{ex.message}" }
    rescue ex : HTTP2::Error
      if connection
        connection.close(error: ex) unless connection.closed?
      end
      @logger.debug { "SENT: #{ex.code}: #{ex.message}" }
    ensure
      if connection
        connection.close unless connection.closed?
      end
    end

    private def context_for(stream : Stream, request = nil)
      unless request
        if stream.state.open?
          body = decode_body(stream.data, stream.headers)
        end
        request = Request.new(stream.headers, body, "HTTP/2.0")
      end
      response = Response.new(stream)
      Context.new(request, response)
    end

    private def handle_request(context : Context)
      @handler.not_nil!.call(context)
    ensure
      context.response.close
      context.request.close
    end
  end
end
