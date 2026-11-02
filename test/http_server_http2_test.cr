require "./test_helper"
require "../src/server"

# The headers an HTTP/2 response sends. Every read on the client side times
# out after 5 seconds, so a response the server doesn't send fails the test
# instead of hanging it.
class HTTP::ServerHTTP2Test < Minitest::Test
  def test_connection_specific_fields_are_not_sent
    headers = response_headers do |response|
      response.headers["Connection"] = "keep-alive"
      response.headers["Keep-Alive"] = "timeout=5"
      response.headers["Transfer-Encoding"] = "chunked"
      response.headers["Upgrade"] = "websocket"
      response.headers["Proxy-Connection"] = "keep-alive"
      response.headers["TE"] = "gzip"
      response.headers["x-custom"] = "kept"
      response.print "ok"
    end

    {"connection", "keep-alive", "transfer-encoding", "upgrade", "proxy-connection", "te"}.each do |name|
      refute headers.has_key?(name), "#{name} sent"
    end
    assert_equal "kept", headers["x-custom"]
    assert_equal "200", headers[":status"]
  end

  def test_te_trailers_is_sent
    headers = response_headers { |response| response.headers["TE"] = "trailers" }
    assert_equal "trailers", headers["te"]
  end

  # Serves one request over HTTP/2 with *handler* and returns the headers of
  # the response.
  private def response_headers(&handler : HTTP::Server::Response ->) : HTTP::Headers
    server = HTTP::Server.new { |context| handler.call(context.response) }
    listener = TCPServer.new("127.0.0.1", 0)
    server.bind(listener)
    spawn { server.listen }

    socket = TCPSocket.new("127.0.0.1", listener.local_address.port)
    socket.read_timeout = 5.seconds
    client = HTTP2::Connection.new(socket, :client)
    client.write_client_preface
    client.write_settings
    client.streams.create.send_headers(HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
    }, HTTP2::Frame::Flags::END_STREAM)

    decoder = HTTP2::HPACK::Decoder.new
    loop do
      size_and_type = socket.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      socket.read_byte # flags
      stream_id = socket.read_bytes(UInt32, IO::ByteFormat::BigEndian) & 0x7fff_ffff
      payload = Bytes.new(size_and_type >> 8)
      socket.read_fully(payload)
      if HTTP2::Frame::Type.new((size_and_type & 0xff).to_u8).headers? && stream_id == 1
        return decoder.decode(payload)
      end
    end
  ensure
    socket.try(&.close)
    server.try(&.close)
  end
end
