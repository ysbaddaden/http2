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
      connection = Connection.new(socket)
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
            connection.write Frame.new(Frame::Type::SETTINGS, frame.stream_id, 0x1)
          end

        when Frame::Type::HEADERS
          # OPTIMIZE: have connection decode the headers
          headers = connection.hpack_decoder.decode(frame.payload)
          method, path = headers[":method"], headers[":path"]
          request = HTTP::Request.new(method, path, headers: headers, version: "HTTP/2.0")

          # FIXME: don't dispatch request until END_HEADERS flag is set!
          # TODO: spawn (requires to write frames through a channel)
          handle_request(connection, frame.stream_id, request)

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
    end

    def handle_request(connection, stream_id, request)
      puts "stream_id=#{stream_id}: #{request.method} #{request.resource} #{request.headers}"

      headers = HTTP::Headers{
        ":status" => "200",
        "content-type" => "text/plain",
        "server" => "h2/0.1.0"
      }
      connection.write Frame.new(Frame::Type::HEADERS,
                                 stream_id,
                                 Frame::Flags::END_HEADERS,
                                 connection.hpack_encoder.encode(headers))

      connection.write Frame.new(Frame::Type::DATA,
                                 stream_id,
                                 Frame::Flags::END_STREAM,
                                 "OK".to_slice)
    end
  end
end

HTTP2::Server.new
