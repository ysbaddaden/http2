require "./test_helper"
require "../src/server"

class HTTP2::ServerTest < Minitest::Test
  def test_serves_streams_in_flight_after_client_goaway
    release = Channel(Nil).new
    server = HTTP::Server.new do |context|
      context.response.print "hello "
      context.response.flush
      release.receive
      context.response.print "world"
    end
    listener = TCPServer.new("127.0.0.1", 0)
    server.bind(listener)
    spawn { server.listen }

    socket = TCPSocket.new("127.0.0.1", listener.local_address.port)
    client = Connection.new(socket, :client)
    client.write_client_preface
    client.write_settings
    stream = client.streams.create
    stream.send_headers(HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
    }, Frame::Flags::END_STREAM)
    receive_until(client) { |frame| frame.type.data? }

    # the client goes away (last_stream_id=0, NO_ERROR) while the response is
    # in flight; the PING ACK tells the server read the GOAWAY
    write_frame(socket, Frame::Type::GOAWAY, Frame::Flags::None, 0, Bytes.new(8))
    write_frame(socket, Frame::Type::PING, Frame::Flags::None, 0, Bytes.new(8))
    receive_until(client) { |frame| frame.type.ping? }

    release.send(nil)
    receive_until(client) { |frame| frame.stream.id == 1 && frame.flags.end_stream? }
    assert_equal "hello world", stream.data.gets_to_end

    # no stream left: the server closes the connection
    write_frame(socket, Frame::Type::PING, Frame::Flags::None, 0, Bytes.new(8))
    receive_until(client) { |frame| frame.type.goaway? }
    assert_raises(IO::Error) { loop { client.receive } }
  ensure
    release.try(&.close)
    socket.try(&.close)
    listener.try(&.close)
  end

  # Receives frames until the block returns true for one.
  private def receive_until(connection, &)
    loop do
      frame = connection.receive
      break if frame && yield frame
    end
  end
end
