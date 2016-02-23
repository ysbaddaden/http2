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
      # TODO: handle HTTP/1 requests
      # TODO: handle HTTP/1 to HTTP/2 upgrade requests
      # TODO: handle HTTP/2 TLS negotiation (through ALPN; requires OpenSSL 1.0.2f)

      connection = Connection.new(socket)
      puts "Connected"

      connection.read_client_preface
      connection.write_settings

      # TODO: raise PROTOCOL_ERROR unless first received frame is a SETTINGS frame

      loop do
        frame = connection.receive
        next unless frame

        case frame.type
        when Frame::Type::SETTINGS
          unless frame.flags.ack?
            # TODO: validate new settings
            connection.write Frame.new(Frame::Type::SETTINGS, frame.stream, 0x1)
          end

        when Frame::Type::HEADERS
          headers = frame.stream.headers
          method, path = headers[":method"], headers[":path"]
          request = HTTP::Request.new(method, path, headers: headers, version: "HTTP/2.0")

          # TODO: spawn (requires to write frames through a channel)
          spawn handle_request(connection, frame.stream, request)

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

    rescue ex
      puts "#{ex.class.name}: #{ex.message}\n#{ex.backtrace.join('\n')}"

    ensure
      if connection
        connection.close unless connection.closed?
      end
      puts "Disconnected"
    end

    def handle_request(connection, stream, request)
      puts "; Handle request"
      request.headers.each do |key, value|
        puts "  #{key.colorize(:light_blue)}: #{value.join(", ")}"
      end

      if %w(POST PATCH PUT).includes?(request.method)
        while line = stream.data.gets
          puts "data: #{line.inspect}"
        end
      end

      push = stream.send_push_promise(HTTP::Headers{
        ":method" => "GET",
        ":path" => "/javascripts/application.js",
        ":authority" => request.headers[":authority"],
        ":scheme" => request.headers[":scheme"],
        "content-type" => "application/javascript",
      })

      headers = HTTP::Headers{
        ":status" => "200",
        "content-type" => "text/plain",
        "server" => "h2/0.1.0"
      }

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
  end
end

HTTP2::Server.new
