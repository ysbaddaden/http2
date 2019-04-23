require "http/request"
require "http/server"
require "logger"
require "socket"
require "./src/http2"

class HTTP::Request
  def initialize(@method : String, @resource : String, @headers : Headers, @version = "HTTP/2.0")
    # NOTE: the original constructor always resets Content-Length to "0",
    #       this is nice for outgoing requests, but it breaks received requests
    #       with a streaming body!
  end
end

module HTTP2
  class Server
    def initialize(host = "::", port = 9292, tls = true)
      TCPServer.open(host, port) do |server|
        loop do
          spawn handle_connection(server.accept, tls)
        end
      end
    end

    @logger : Logger|Logger::Dummy|Nil

    def logger
      @logger ||= Logger.new(STDOUT).tap do |logger|
        logger.level = Logger::Severity::DEBUG
        logger.formatter = Logger::Formatter.new do |s, d, p, message, io|
          io << message
        end
      end
    end

    def logger=(@logger)
      @logger = logger
    end

    def handle_connection(socket, tls = true)
      if tls
        socket = OpenSSL::SSL::Socket::Server.new(socket, tls_context)
      end

      if ENV["DEBUG"]?
        socket = IO::Hexdump.new(socket, STDERR, read: true)
      end

      if line = socket.gets
        method, resource, protocol = line.split
      else
        return
      end

      if protocol == "HTTP/2.0"
        handle_http2_connection(socket)
      elsif protocol.starts_with?("HTTP/")
        handle_http1_connection(socket, method, resource, protocol)
      end
    rescue ex : OpenSSL::SSL::Error
      logger.debug { "#{ex.class.name}: #{ex.message}" }
    rescue ex
      logger.debug { "#{ex.class.name}: #{ex.message}\n#{ex.backtrace.join('\n')}" }
      #logger.debug { "#{ex.class.name}: #{ex.message}" }
    ensure
      # FIXME: OpenSSL::SSL::Socket is missing a closed? method
      socket.close #unless socket.closed?
    end

    def handle_http1_connection(socket, method, resource, protocol)
      headers = HTTP::Headers.new

      while line = socket.gets
        break if line.strip.empty?
        name, value = line.split(": ")
        headers.add(name, value.strip)
      end

      if settings = upgradeable_to_http2?(headers)
        socket << "HTTP/1.1 101 Switching Protocols\r\n"
        socket << "Connection: Upgrade\r\n"
        socket << "Upgrade: h2c\r\n"
        socket << "\r\n"
        settings = Base64.decode(headers.get("HTTP2-Settings").first)
        request = HTTP::Request.new(method, resource, headers, version: "HTTP/2.0")
        handle_http2_connection(socket, request, raw_settings: settings)
      else
        request = HTTP::Request.new(method, resource, headers, version: protocol)
        handle_http1_request(socket, request)
      end
    end

    def upgradeable_to_http2?(headers)
      return unless headers["upgrade"]? == "h2c"
      return unless settings = headers.get?("http2-settings")
      settings.first if settings.size == 1
    end

    def handle_http2_connection(socket, request = nil, raw_settings = nil)
      connection = Connection.new(socket, Connection::Type::SERVER, logger)
      logger.debug { "Connected" }

      if raw_settings
        connection.remote_settings.parse(raw_settings) do |setting, value|
          logger.debug { "  #{setting}=#{value}" }
        end
      end
      connection.read_client_preface(truncated: request == nil)
      connection.write_settings

      frame = connection.receive
      unless frame.try(&.type) == Frame::Type::SETTINGS
        raise Error.protocol_error("EXPECTED settings frame")
      end

      if request.is_a?(HTTP::Request)
        stream = connection.streams.find(1)

        # FIXME: the cast is required for Crystal to compile
        spawn handle_http2_request(stream, request.as(HTTP::Request))
      end

      loop do
        next unless frame = connection.receive

        case frame.type
        when Frame::Type::HEADERS
          # don't dispatch twice
          next if frame.stream.trailing_headers?

          # TODO: move the following validations to HPACK decoder (add mecanism to validate headers as they are decoded)
          headers = frame.stream.headers
          regular = false

          headers.each do |name, value|
            regular ||= !name.starts_with?(':')
            if (name.starts_with?(':') && (regular || !REQUEST_PSEUDO_HEADERS.includes?(name))) || ("A" .. "Z").covers?(name)
              raise Error.protocol_error("MALFORMED #{name} header")
            end
            if name == "connection"
              raise Error.protocol_error("MALFORMED #{name} header")
            end
            if name == "te" && value != "trailers"
              raise Error.protocol_error("MALFORMED #{name} header")
            end
          end

          unless headers.get?(":method").try(&.size.==(1))
            raise Error.protocol_error("INVALID :method pseudo-header")
          end

          unless headers[":method"] == "CONNECT"
            %w(:scheme :path).each do |name|
              unless headers.get?(name).try(&.size.==(1))
                raise Error.protocol_error("INVALID #{name} pseudo-header")
              end
            end
          end

          req = HTTP::Request.new(headers[":method"], headers[":path"], headers, version: "HTTP/2.0")
          spawn handle_http2_request(frame.stream, req)

        when Frame::Type::PUSH_PROMISE
          raise Error.protocol_error("UNEXPECTED push promise frame")

        when Frame::Type::GOAWAY
          break
        end
      end

    rescue err : ClientError
      logger.debug { "#{err.code}: #{err.message}" }

    rescue err : Error
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

    def handle_http2_request(stream, request)
      if %w(POST PATCH PUT).includes?(request.method)
        while line = stream.data.gets
          logger.debug {  "data: #{line.inspect}" }
        end
      end

      authority = request.headers[":authority"]? || request.headers["Host"]
      scheme = request.headers[":scheme"]? || "http"

      #appjs = stream.send_push_promise(HTTP::Headers{
      #  ":method" => "GET",
      #  ":path" => "/javascripts/application.js",
      #  ":authority" => authority,
      #  ":scheme" => scheme,
      #  "content-type" => "application/javascript",
      #})
      #favicon = stream.send_push_promise(HTTP::Headers{
      #  ":method" => "GET",
      #  ":path" => "/favicon.ico",
      #  ":authority" => authority,
      #  ":scheme" => scheme,
      #})

      status, headers, body = handle_request(request)
      headers[":status"] = status

      if request.method == "HEAD"
        stream.send_headers(headers, Frame::Flags::END_STREAM)
      else
        stream.send_headers(headers)
        stream.send_data(body)
        stream.send_data("", Frame::Flags::END_STREAM)
      end

      #if appjs && appjs.try(&.state) != Stream::State::CLOSED
      #  appjs.send_headers(HTTP::Headers{
      #     ":status" => "200",
      #     "content-type" => "application/javascript",
      #  })
      #  appjs.send_data("(function () { console.log('server push!'); }());", Frame::Flags::END_STREAM)
      #end
      #if favicon && favicon.try(&.state) != Stream::State::CLOSED
      #  favicon.send_headers(HTTP::Headers{ ":status" => "404" }, Frame::Flags::END_STREAM)
      #end
    ensure
      stream.data.close
    end

    def handle_http1_request(socket, request)
      if size = request.headers["content-length"]?
        #socket.read_fully(buf = Slice(UInt8).new(size.to_i))
        #p String.new(buf)
        socket.skip(size.to_i)
      end

      status, headers, body = handle_request(request)
      socket << "#{request.version} #{status} OK\r\n"
      headers.each { |key, value| socket << "#{key}: #{value.join(", ")}\r\n" }
      socket << "\r\n"
      socket << body unless request.method == "HEAD"
    end

    def handle_request(request)
      logger.debug { "; Handle request:\n  #{request.method} #{request.resource}" }
      request.headers.each do |key, value|
        logger.debug { "  #{key.colorize(:light_blue)}: #{value.join(", ")}" }
      end

      headers = HTTP::Headers{
        "content-type" => "text/html",
        "server" => "h2/0.1.0"
      }
      body = <<-HTML
        <!DOCTYPE html>
        <html>
        <head>
          <title>#{request.version} on Crystal</title>
          <script src="/javascripts/application.js"></script>
        </head>
        <body>
          Served with #{request.version}
        </body>
        </html>
        HTML

      {"200", headers, body}
    end

    @tls_context : OpenSSL::SSL::Context::Server?

    private def tls_context
      @tls_context ||= begin
        ctx = OpenSSL::SSL::Context::Server.new
        ctx.alpn_protocol = "h2"
        ctx.certificate_chain = tls_path(:crt)
        ctx.private_key = tls_path(:key)
        ctx
      end
    end

    private def tls_path(extname)
      File.join("ssl", "server.#{extname}")
    end
  end
end

HTTP2::Server.new
