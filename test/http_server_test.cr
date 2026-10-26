require "./test_helper"
require "../src/server"

class HTTP::ServerTest < Minitest::Test
  def test_close_stops_the_server
    server = HTTP::Server.new { |context| context.response.print "ok" }
    listener = TCPServer.new("127.0.0.1", 0)
    server.bind(listener)

    stopped = Channel(Nil).new(1)
    spawn do
      server.listen
      stopped.send(nil)
    end

    # a response tells the server is listening
    socket = TCPSocket.new("127.0.0.1", listener.local_address.port)
    socket.read_timeout = 5.seconds
    socket << "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"
    socket.flush
    assert_equal "HTTP/1.1 200 OK", socket.gets

    server.close
    assert server.closed?
    assert listener.closed?

    select
    when stopped.receive
    when timeout(5.seconds)
      flunk "HTTP::Server#listen didn't return"
    end
  ensure
    socket.try(&.close)
    listener.try(&.close)
  end
end
