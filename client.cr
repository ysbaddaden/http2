require "socket"
require "openssl"
require "./src/connection"

module HTTP2
  class Client
    @connection : Connection
    @requests = {} of Stream => Channel(Nil)

    def initialize(host : String, port : Int32, ssl_context)
      @authority = "#{host}:#{port}"

      io = TCPSocket.new(host, port)

      case ssl_context
      when true
        ssl_context = OpenSSL::SSL::Context::Client.new
        ssl_context.alpn_protocol = "h2"
        io = OpenSSL::SSL::Socket::Client.new(io, ssl_context)
        @scheme = "https"
      when OpenSSL::SSL::Context::Client
        ssl_context.alpn_protocol = "h2"
        io = OpenSSL::SSL::Socket::Client.new(io, ssl_context)
        @scheme = "https"
      else
        @scheme = "http"
      end

      connection = Connection.new(io, Connection::Type::CLIENT)
      connection.write_client_preface
      connection.write_settings

      frame = connection.receive
      unless frame.try(&.type) == Frame::Type::SETTINGS
        raise Error.protocol_error("Expected SETTINGS frame")
      end

      @connection = connection
      spawn handle_connection
    end

    private def handle_connection
      loop do
        unless frame = @connection.receive
          next
        end
        case frame.type
        when Frame::Type::HEADERS
          @requests[frame.stream].send(nil)
        when Frame::Type::PUSH_PROMISE
          # TODO: got SERVER PUSHed headers
        when Frame::Type::GOAWAY
          break
        else
          # shut up, crystal
        end
      end
    end

    def request(headers : HTTP::Headers)
      headers[":authority"] = @authority
      headers[":scheme"] ||= @scheme

      stream = @connection.streams.create
      @requests[stream] = Channel(Nil).new

      stream.send_headers(headers)
      @requests[stream].receive

      yield stream.headers, stream.data

      if stream.active?
        stream.send_rst_stream(Error::Code::NO_ERROR)
      end
    end

    def close
      @connection.close unless closed?
    end

    def closed?
      @connection.closed?
    end
  end
end

Log.for("http2").level = Log::Severity::Debug

client = HTTP2::Client.new("localhost", 9292, !!ENV["TLS"]?)

10.times do |i|
  headers = HTTP::Headers{
    ":method" => "GET",
    ":path" => "/",
    "user-agent" => "crystal h2/0.0.0"
  }

  client.request(headers) do |headers, body|
    puts "REQ ##{i}: #{headers.inspect}"

    while line = body.gets
      puts "REQ ##{i}: #{line}"
    end
  end
end

client.close
