require "openssl"
require "logger"
require "./src/connection"

module HTTP2
  class Server
    @ssl_context : OpenSSL::SSL::Context::Server?
    @logger : Logger

    def initialize(host : String, port : Int32, ssl_context = nil, logger = nil)
      @server = TCPServer.new(host, port)
      @logger = logger || Logger::Dummy.new

      if ssl_context
        ssl_context.alpn_protocol = "h2"
        @ssl_context = ssl_context
      end
    end

    def listen
      loop do
        spawn handle_socket(@server.accept)
      end
    end

    private def handle_socket(io : IO)
      if ssl_context = @ssl_context
        io = OpenSSL::SSL::Socket::Server.new(io, ssl_context)
      end
      handle_connection(io)
    ensure
      begin
        io.close unless io.closed?
      rescue ex : Errno
        raise ex unless {Errno::EPIPE, Errno::ECONNRESET}.includes?(ex.errno)
      rescue IO::EOFError | IO::Error
      end
    end

    private def handle_connection(io : IO)
      connection = Connection.new(io, Connection::Type::SERVER, @logger)
      connection.read_client_preface(truncated: false)
      connection.write_settings

      frame = connection.receive
      unless frame.try(&.type) == Frame::Type::SETTINGS
        raise Error.protocol_error("Expected SETTINGS frame")
      end

      loop do
        unless frame = connection.receive
          next
        end
        case frame.type
        when Frame::Type::HEADERS
          next if frame.stream.trailing_headers? # don't dispatch twice
          spawn handle_request(frame.stream)
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

    private def handle_request(stream : Stream)
      method = stream.headers[":method"]
      path = stream.headers[":path"]

      case method
      when "PUT"
        if path == "/echo"
          headers = HTTP::Headers{
            ":status" => "200",
            "server" => "h3/0.0.0",
            "content-length" => stream.headers["content-length"],
          }

          if type = stream.headers["content-type"]?
            headers["content-type"] = type
          end
          stream.send_headers(headers)

          buffer = Bytes.new(8192)

          loop do
            count = stream.data.read(buffer)
            break if count == 0
            stream.send_data(buffer[0, count])
          end

          stream.send_data("", flags: Frame::Flags::END_STREAM)
          return
        end
      end

      not_found(stream)
    ensure
      stream.data.close_read
    end

    private def not_found(stream : Stream)
      stream.send_headers(HTTP::Headers{
        ":status" => "404",
        "content-type" => "text/plain",
        "server" => "h3/0.0.0",
      })
      stream.send_data("404 NOT FOUND", flags: Frame::Flags::END_STREAM)
    end
  end
end

if ENV["TLS"]?
  ssl_context = OpenSSL::SSL::Context::Server.new
  ssl_context.certificate_chain = File.join(__DIR__, "ssl", "server.crt")
  ssl_context.private_key = File.join(__DIR__, "ssl", "server.key")
end

unless ENV["CI"]?
  logger = Logger.new(STDOUT)
  logger.level = Logger::DEBUG
end

host = ENV["HOST"]? || "::"
port = (ENV["PORT"]? || 9292).to_i

server = HTTP2::Server.new(host, port, ssl_context, logger)

if ssl_context
  puts "listening on https://#{host}:#{port}/"
else
  puts "listening on http://#{host}:#{port}/"
end
server.listen
