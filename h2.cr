require "http/request"
require "logger"
require "socket"
require "./src/http2"
require "./src/core_ext/openssl"

class IO::Hexdump
  include IO

  def initialize(@io : IO, @logger : Logger|Logger::Dummy)
  end

  def read(buf : Slice(UInt8))
    @io.read(buf).tap do |ret|
      offset = 0
      line = MemoryIO.new(48)

      message = String.build do |str|
        buf.each_with_index do |byte, index|
          if index > 0
            if index % 16 == 0
              str.print line.to_s
              hexdump(buf, offset, str)
              str.print '\n'
              line = MemoryIO.new(48)
            elsif index % 8 == 0
              line.print "  "
            else
              line.print ' '
            end
          end

          s = byte.to_s(16)
          line.print '0' if s.size == 1
          line.print s

          offset = index
        end

        if line.pos > 0
          str.print line.to_s
          (48 - line.pos).times { str.print ' ' }
          hexdump(buf, offset, str)
        end
      end

      @logger.debug(message)
    end
  end

  def write(buf : Slice(UInt8))
    @io.write(buf)
  end

  private def hexdump(buf, offset, str)
    str.print "  |"

    buf[offset - 8 < 0 ? 0 : offset - 8, (offset % 8) + 1].each do |byte|
      if 31 < byte < 127
        str.print byte.chr
      else
        str.print '.'
      end
    end

    str.print '|'
  end
end

module HTTP2
  class Server
    def initialize(host = "::", port = 9292, ssl = true)
      TCPServer.open(host, port) do |server|
        loop do
          spawn handle_connection(server.accept, ssl)
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

    def handle_connection(socket, ssl = true)
      if ssl
        socket = OpenSSL::SSL::Socket.new(socket, :server, ssl_context)
      end

      socket = IO::Hexdump.new(socket, logger)

      if line = socket.gets
        method, resource, protocol = line.split
      else
        return
      end

      if protocol == "HTTP/2.0"
        handle_http2_connection(socket)
      else
        handle_http1_connection(socket, method, resource, protocol)
      end
    rescue ex
      logger.debug { "#{ex.class.name}: #{ex.message}\n#{ex.backtrace.join('\n')}" }
    ensure
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
        request = HTTP::Request.new(method, resource, headers: headers, version: "HTTP/2.0")
        handle_http2_connection(socket, request, raw_settings: settings)
      else
        request = HTTP::Request.new(method, resource, headers: headers, version: protocol)
        handle_http1_request(socket, request)
      end
    end

    def upgradeable_to_http2?(headers)
      return unless headers["upgrade"]? == "h2c"
      return unless settings = headers.get?("http2-settings")
      settings.first if settings.size == 1
    end

    def handle_http2_connection(socket, request = nil, raw_settings = nil)
      connection = Connection.new(socket, logger)
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
        Error.protocol_error("EXPECTED settings frame")
      end

      if request.is_a?(HTTP::Request)
        stream = connection.streams.find_or_create(1)

        # FIXME: the cast is required for Crystal to compile
        spawn handle_http2_request(stream, request as HTTP::Request)
      end

      loop do
        next unless frame = connection.receive

        case frame.type
        when Frame::Type::HEADERS
          headers = frame.stream.headers
          method, path = headers[":method"], headers[":path"]
          req = HTTP::Request.new(method, path, headers: headers, version: "HTTP/2.0")
          spawn handle_http2_request(frame.stream, req)
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

      appjs = stream.send_push_promise(HTTP::Headers{
        ":method" => "GET",
        ":path" => "/javascripts/application.js",
        ":authority" => authority,
        ":scheme" => scheme,
        "content-type" => "application/javascript",
      })
      favicon = stream.send_push_promise(HTTP::Headers{
        ":method" => "GET",
        ":path" => "/favicon.ico",
        ":authority" => authority,
        ":scheme" => scheme,
      })

      status, headers, body = handle_request(request)
      headers[":status"] = status

      if request.method == "HEAD"
        stream.send_headers(headers, Frame::Flags::END_STREAM)
      else
        stream.send_headers(headers)
        stream.send_data(body)
        stream.send_data("", Frame::Flags::END_STREAM)
      end

      if appjs && appjs.try(&.state) != Stream::State::CLOSED
        appjs.send_headers(HTTP::Headers{
           ":status" => "200",
           "content-type" => "application/javascript",
        })
        appjs.send_data("(function () { console.log('server push!'); }());", Frame::Flags::END_STREAM)
      end
      if favicon && favicon.try(&.state) != Stream::State::CLOSED
        favicon.send_headers(HTTP::Headers{ ":status" => "404" }, Frame::Flags::END_STREAM)
      end
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

    private def ssl_context
      @ssl_context ||= OpenSSL::SSL::Context.new(LibSSL.tlsv1_2_method) do |ctx|
        ctx.options = LibSSL::SSL_OP_NO_SSLv2 | LibSSL::SSL_OP_NO_SSLv3 | LibSSL::SSL_OP_CIPHER_SERVER_PREFERENCE
        ctx.ciphers = HTTP2::TLS_CIPHERS
        ctx.set_tmp_ecdh_key(curve: LibSSL::NID_X9_62_prime256v1)
        ctx.alpn_protocol = "h2"
        ctx.certificate_chain = ssl_path(:crt)
        ctx.private_key = ssl_path(:key)
      end
    end

    private def ssl_path(extname)
      File.join("ssl", "server.#{extname}")
    end
  end
end

HTTP2::Server.new
