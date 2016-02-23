require "socket"
require "http/request"
require "./src/http2"

module HTTP2
  class Server
    def initialize(host = "::", port = 9292)
      TCPServer.open(host, port) do |server|
        loop do
          spawn handle_connection(server.accept)
        end
      end
    end

    def handle_connection(socket)
      # TODO: handle HTTP/2 TLS negotiation (through ALPN; requires OpenSSL 1.0.2f)

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
      puts "#{ex.class.name}: #{ex.message}\n#{ex.backtrace.join('\n')}"
    ensure
      socket.close unless socket.closed?
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
      connection = Connection.new(socket)
      puts "Connected"

      if raw_settings
        connection.remote_settings.parse(raw_settings)
      end
      connection.read_client_preface(truncated: request == nil)
      connection.write_settings

      frame = connection.receive
      unless frame.try(&.type) == Frame::Type::SETTINGS
        Error.protocol_error("EXPECTED settings frame")
      end

      if request.is_a?(HTTP::Request)
        stream = connection.find_or_create_stream(1)

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
      puts "#{err.code}: #{err.message}"

    rescue err : Error
      if connection
        connection.close(error: err) unless connection.closed?
      end
      puts "#{err.code}: #{err.message}"

    ensure
      if connection
        connection.close unless connection.closed?
      end
      puts "Disconnected"
    end

    def handle_http2_request(stream, request)
      if %w(POST PATCH PUT).includes?(request.method)
        while line = stream.data.gets
          puts "data: #{line.inspect}"
        end
      end

      authority = request.headers[":authority"]? || request.headers["Host"]
      scheme = request.headers[":scheme"]? || "http"

      push = stream.send_push_promise(HTTP::Headers{
        ":method" => "GET",
        ":path" => "/javascripts/application.js",
        ":authority" => authority,
        ":scheme" => scheme,
        "content-type" => "application/javascript",
      })

      status, headers, body = handle_request(request)
      headers[":status"] = status

      if request.method == "HEAD"
        stream.send_headers(headers, Frame::Flags::END_STREAM)
      else
        stream.send_headers(headers)
        stream.send_data("OK")
        stream.send_data("", Frame::Flags::END_STREAM)
      end

      if push && push.try(&.state) != Stream::State::CLOSED
        push.send_headers(HTTP::Headers{
           ":status" => "200",
           "content-type" => "application/javascript",
        })
        push.send_data("(function () {}());", Frame::Flags::END_STREAM)
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
      puts "; Handle request:\n  #{request.method} #{request.resource}"
      request.headers.each do |key, value|
        puts "  #{key.colorize(:light_blue)}: #{value.join(", ")}"
      end

      headers = HTTP::Headers{ "content-type" => "text/plain", "server" => "h2/0.1.0" }
      {"200", headers, "OK"}
    end
  end
end

HTTP2::Server.new
