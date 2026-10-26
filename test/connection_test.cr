require "./test_helper"
require "../src/http2"

class HTTP2::ConnectionTest < Minitest::Test
  def test_headers_frame_with_end_stream_closes_the_stream
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM,
      2,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "204"})
    }
    connection = new_connection(:client, headers_frame)
    frame = connection.receive.not_nil!
    assert_empty frame.stream.data.gets_to_end
  end

  def test_saves_reset_stream_error_code_to_frame
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS,
      2,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"})
    }
    reset_stream_frame = {
      Frame::Type::RST_STREAM,
      Frame::Flags::None,
      2,
      Bytes[0, 0, 0, 7], # REFUSED_STREAM
    }
    connection = new_connection(:client, headers_frame, reset_stream_frame)
    connection.receive

    frame = connection.receive.not_nil!
    assert_equal Frame::Type::RST_STREAM, frame.type
    assert_equal Error::Code::REFUSED_STREAM, frame.error
  end

  def test_client_respects_server_advertised_max_concurrent_streams
    # max_concurrent_streams=1
    settings_frame = {Frame::Type::SETTINGS, Frame::Flags::None, 0, Bytes[0, 3, 0, 0, 0, 1]}
    connection = new_connection(:client, settings_frame)
    connection.receive

    stream = connection.streams.create(state: Stream::State::OPEN)
    assert_equal 1, stream.id

    error = assert_raises(Error) { connection.streams.create }
    assert_equal Error::Code::REFUSED_STREAM, error.code
  end

  def test_server_respects_client_advertised_max_concurrent_streams
    # max_concurrent_streams=1
    settings_frame = {Frame::Type::SETTINGS, Frame::Flags::None, 0, Bytes[0, 3, 0, 0, 0, 1]}
    connection = new_connection(:server, settings_frame)
    connection.receive

    stream = connection.streams.create(state: Stream::State::OPEN)
    assert_equal 2, stream.id

    error = assert_raises(Error) { connection.streams.create }
    assert_equal Error::Code::REFUSED_STREAM, error.code
  end

  def test_server_enforces_local_max_concurrent_streams_for_client_initiated_streams
    headers = HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
    })
    stream1 = {Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1, headers}
    stream2 = {Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 3, headers}
    connection = new_connection(:server, stream1, stream2)

    connection.local_settings.max_concurrent_streams = 1
    connection.receive

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::REFUSED_STREAM, error.code
  end

  def test_client_accepts_frames_on_streams_it_opened
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM,
      1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}),
    }
    connection = new_connection(:client, headers_frame)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)

    frame = connection.receive.not_nil!
    assert_same stream, frame.stream
    assert_equal "200", stream.headers[":status"]
    assert_equal Stream::State::CLOSED, stream.state
  end

  def test_client_rejects_frames_on_streams_it_did_not_open
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM,
      3,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}),
    }
    connection = new_connection(:client, headers_frame)
    connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code
  end

  def test_sending_headers_frame_with_end_stream_half_closes_the_local_side
    connection = new_connection(:client)
    stream = connection.streams.create
    stream.send_headers(HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
    }, Frame::Flags::END_STREAM)
    assert_equal Stream::State::HALF_CLOSED_LOCAL, stream.state
  end

  def test_receiving_headers_frame_with_end_stream_half_closes_the_remote_side
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM,
      1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{
        ":method"    => "GET",
        ":scheme"    => "http",
        ":authority" => "example.com",
        ":path"      => "/",
      }),
    }
    connection = new_connection(:server, headers_frame)
    frame = connection.receive.not_nil!
    assert_equal Stream::State::HALF_CLOSED_REMOTE, frame.stream.state
  end

  def test_client_sends_connection_window_update
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}))
    3.times { write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, Bytes.new(16384)) }
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)

    4.times { connection.receive }
    assert_equal [{0, DEFAULT_INITIAL_WINDOW_SIZE}], window_updates(output)
  end

  def test_received_rst_stream_releases_body_reader
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS,
      1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}),
    }
    reset_stream_frame = {Frame::Type::RST_STREAM, Frame::Flags::None, 1, Bytes[0, 0, 0, 8]} # CANCEL
    connection = new_connection(:client, headers_frame, reset_stream_frame)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    connection.receive

    result = Channel(String | Exception).new(1)
    spawn do
      result.send(stream.data.gets_to_end)
    rescue ex
      result.send(ex)
    end
    Fiber.yield # let the reader block on the empty body

    connection.receive

    select
    when value = result.receive
      assert_instance_of IO::Error, value
    when timeout(1.second)
      flunk "body reader is still blocked after RST_STREAM"
    end
  end

  def test_received_rst_stream_keeps_complete_body
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS,
      1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}),
    }
    data_frame = {Frame::Type::DATA, Frame::Flags::END_STREAM, 1, "hello".to_slice}
    reset_stream_frame = {Frame::Type::RST_STREAM, Frame::Flags::None, 1, Bytes[0, 0, 0, 0]} # NO_ERROR
    connection = new_connection(:client, headers_frame, data_frame, reset_stream_frame)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)

    3.times { connection.receive }
    assert_equal "hello", stream.data.gets_to_end
  end

  def test_received_rst_stream_releases_blocked_sender
    input = IO::Memory.new
    write_frame(input, Frame::Type::RST_STREAM, Frame::Flags::None, 1, Bytes[0, 0, 0, 8]) # CANCEL
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)
    stream = connection.streams.create(state: Stream::State::OPEN)

    result = Channel(Exception?).new(1)
    spawn do
      # one byte more than the stream window: blocks until a WINDOW_UPDATE
      stream.send_data(Bytes.new(DEFAULT_INITIAL_WINDOW_SIZE + 1))
      result.send(nil)
    rescue ex
      result.send(ex)
    end
    Fiber.yield # let the sender block on the exhausted window

    connection.receive

    select
    when value = result.receive
      assert_instance_of Error, value
    when timeout(1.second)
      flunk "sender is still blocked after RST_STREAM"
    end
  end

  def test_close_releases_body_reader
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS,
      1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}),
    }
    connection = new_connection(:client, headers_frame)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    connection.receive

    result = Channel(String | Exception).new(1)
    spawn do
      result.send(stream.data.gets_to_end)
    rescue ex
      result.send(ex)
    end
    Fiber.yield # let the reader block on the empty body

    connection.close

    select
    when value = result.receive
      assert_instance_of IO::Error, value
    when timeout(1.second)
      flunk "body reader is still blocked after the connection was closed"
    end
    assert_equal Stream::State::CLOSED, stream.state
  end

  def test_close_releases_blocked_sender
    connection = Connection.new(IO::Stapled.new(IO::Memory.new, IO::Memory.new), :client)
    stream = connection.streams.create(state: Stream::State::OPEN)

    result = Channel(Exception?).new(1)
    spawn do
      # one byte more than the stream window: blocks until a WINDOW_UPDATE
      stream.send_data(Bytes.new(DEFAULT_INITIAL_WINDOW_SIZE + 1))
      result.send(nil)
    rescue ex
      result.send(ex)
    end
    Fiber.yield # let the sender block on the exhausted window

    connection.close

    select
    when value = result.receive
      assert_instance_of Error, value
    when timeout(1.second)
      flunk "sender is still blocked after the connection was closed"
    end
  end

  def test_close_silences_any_error_writing_goaway
    output = RaisingWriter.new
    connection = Connection.new(IO::Stapled.new(IO::Memory.new, output), :client)
    stream = connection.streams.create(state: Stream::State::OPEN)

    # a TLS socket raises OpenSSL::SSL::Error, which isn't an IO::Error
    output.error = NotAnIOError.new("bad record mac")
    connection.close

    assert connection.closed?
    assert_equal Stream::State::CLOSED, stream.state
  end

  private class NotAnIOError < Exception
  end

  # Raises *error* on every write once it's set.
  private class RaisingWriter < IO
    property error : Exception? = nil

    def read(slice : Bytes) : Int32
      0
    end

    def write(slice : Bytes) : Nil
      if error = @error
        raise error
      end
    end
  end

  def test_close_keeps_complete_body
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS,
      1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}),
    }
    data_frame = {Frame::Type::DATA, Frame::Flags::END_STREAM, 1, "hello".to_slice}
    connection = new_connection(:client, headers_frame, data_frame)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    2.times { connection.receive }

    connection.close
    assert_equal "hello", stream.data.gets_to_end
  end

  def test_received_goaway_lets_active_streams_complete
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS,
      1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}),
    }
    goaway_frame = {Frame::Type::GOAWAY, Frame::Flags::None, 0, Bytes[0, 0, 0, 1, 0, 0, 0, 0]} # last_stream_id=1, NO_ERROR
    data_frame = {Frame::Type::DATA, Frame::Flags::END_STREAM, 1, "hello".to_slice}
    connection = new_connection(:client, headers_frame, goaway_frame, data_frame)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)

    3.times { connection.receive }
    assert connection.closed?
    assert_equal "hello", stream.data.gets_to_end
  end

  def test_close_after_received_goaway_releases_body_reader
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS,
      1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}),
    }
    goaway_frame = {Frame::Type::GOAWAY, Frame::Flags::None, 0, Bytes[0, 0, 0, 1, 0, 0, 0, 0]} # last_stream_id=1, NO_ERROR
    connection = new_connection(:client, headers_frame, goaway_frame)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    2.times { connection.receive }

    result = Channel(String | Exception).new(1)
    spawn do
      result.send(stream.data.gets_to_end)
    rescue ex
      result.send(ex)
    end
    Fiber.yield # let the reader block on the empty body

    # e.g. the peer closed the socket before the stream completed
    connection.close

    select
    when value = result.receive
      assert_instance_of IO::Error, value
    when timeout(1.second)
      flunk "body reader is still blocked after the connection was closed"
    end
  end

  def test_write_failure_closes_connection
    output = FailingWriter.new
    connection = Connection.new(IO::Stapled.new(IO::Memory.new, output), :client)
    stream = connection.streams.create(state: Stream::State::OPEN)

    output.fail_next_payload = true
    assert_raises(IO::Error) { stream.send_data(Bytes.new(100)) }
    assert connection.closed?
    assert_equal Stream::State::CLOSED, stream.state

    # the frame header is on the wire without its payload: nothing else may
    # follow, even though the IO would accept writes again
    written = output.bytesize
    assert_raises(IO::Error) { connection.send_settings }
    assert_equal written, output.bytesize
  end

  # Fails the next write of a frame payload when armed, once.
  private class FailingWriter < IO
    property? fail_next_payload = false
    getter bytesize = 0

    def read(slice : Bytes) : Int32
      0
    end

    def write(slice : Bytes) : Nil
      if fail_next_payload? && slice.size > 9 # larger than any header field write
        @fail_next_payload = false
        raise IO::Error.new("write failed")
      end
      @bytesize += slice.size
    end
  end

  # Parses the WINDOW_UPDATE frames written to *io* as {stream_id, increment}.
  private def window_updates(io : IO::Memory)
    io.rewind
    updates = [] of {Int32, Int32}
    while io.pos < io.size
      header = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      size, type = header >> 8, header & 0xff
      io.skip(1) # flags
      stream_id = io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i32 & 0x7fffffff
      if type == Frame::Type::WINDOW_UPDATE.value
        updates << {stream_id, io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i32 & 0x7fffffff}
      else
        io.skip(size)
      end
    end
    updates
  end
end
