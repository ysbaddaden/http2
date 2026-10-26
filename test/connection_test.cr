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

  def test_ignores_frames_in_flight_on_streams_it_reset
    encoder = HPACK::Encoder.new(indexing: HPACK::Indexing::ALWAYS, huffman: false)
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      encoder.encode(HTTP::Headers{":status" => "200"}))
    # sent by the server before it received the RST_STREAM
    3.times { write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, Bytes.new(16384)) }
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1,
      encoder.encode(HTTP::Headers{"x-trailer" => "1"}))
    # refers to the dynamic table entry the trailers above added
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 3,
      encoder.encode(HTTP::Headers{":status" => "200", "x-trailer" => "1"}))
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    stream1 = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    stream3 = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    connection.receive

    stream1.send_rst_stream(Error::Code::CANCEL)
    refute_same stream1, connection.streams.find(1), "stream 1 is still in the stream table"
    4.times { assert_nil connection.receive }

    frame = connection.receive.not_nil!
    assert_same stream3, frame.stream
    assert_equal "1", stream3.headers["x-trailer"]
    # the ignored DATA still counts against the connection window
    assert_equal [{0, DEFAULT_INITIAL_WINDOW_SIZE}], window_updates(output)
  end

  def test_rejects_frames_on_closed_streams_it_did_not_reset_while_active
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}))
    write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, "hello".to_slice)
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    connection.receive

    # resetting a closed stream leaves no frames in flight
    stream.send_rst_stream(Error::Code::NO_ERROR)
    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::STREAM_CLOSED, error.code
  end

  def test_client_accepts_response_to_head_request_with_content_length
    stream, connection, _ = bodiless_response("HEAD", "200")

    frame = connection.receive.not_nil!
    assert_same stream, frame.stream
    assert_equal "1000", stream.headers["content-length"]
    assert_empty stream.data.gets_to_end
  end

  def test_client_accepts_not_modified_response_with_content_length
    stream, connection, _ = bodiless_response("GET", "304")

    frame = connection.receive.not_nil!
    assert_same stream, frame.stream
    assert_empty stream.data.gets_to_end
  end

  def test_client_resets_stream_on_content_length_and_no_body
    stream, connection, output = bodiless_response("GET", "200")

    assert_nil connection.receive
    assert_equal [{1, Error::Code::PROTOCOL_ERROR}], reset_streams(output)
    assert_raises(IO::Error) { stream.data.gets_to_end }
  end

  # Sends a *method* request on stream 1, whose response is HEADERS with
  # END_STREAM, *status* and `content-length: 1000`, without DATA.
  private def bodiless_response(method, status)
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => status, "content-length" => "1000"}))
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    stream = connection.streams.create
    stream.send_headers(HTTP::Headers{
      ":method"    => method,
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
    }, Frame::Flags::END_STREAM)
    {stream, connection, output}
  end

  def test_content_length_mismatch_resets_the_stream
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200", "content-length" => "10"}))
    write_frame(input, Frame::Type::DATA, Frame::Flags::END_STREAM, 1, "hello".to_slice)
    write_frame(input, Frame::Type::PING, Frame::Flags::None, 0, Bytes.new(8))
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    connection.receive

    assert_nil connection.receive
    assert_equal [{1, Error::Code::PROTOCOL_ERROR}], reset_streams(output)
    assert_raises(IO::Error) { stream.data.gets_to_end }

    # a stream error: the connection goes on
    assert_equal Frame::Type::PING, connection.receive.not_nil!.type
  end

  def test_invalid_content_length_resets_the_stream
    # not digits only, or too large (RFC 9110 section 8.6)
    {"abc", "+5", "5 ", "99999999999999999999"}.each do |content_length|
      input = IO::Memory.new
      write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
        HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200", "content-length" => content_length}))
      write_frame(input, Frame::Type::DATA, Frame::Flags::END_STREAM, 1, "hello".to_slice)
      write_frame(input, Frame::Type::PING, Frame::Flags::None, 0, Bytes.new(8))
      input.rewind
      output = IO::Memory.new
      connection = Connection.new(IO::Stapled.new(input, output), :client)
      stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
      connection.receive

      assert_nil connection.receive, "content-length: #{content_length.inspect}"
      assert_equal [{1, Error::Code::PROTOCOL_ERROR}], reset_streams(output)
      assert_raises(IO::Error) { stream.data.gets_to_end }

      # a stream error: the connection goes on
      assert_equal Frame::Type::PING, connection.receive.not_nil!.type
    end
  end

  def test_server_resets_request_stream_on_content_length_mismatch
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{
        ":method"        => "POST",
        ":scheme"        => "http",
        ":authority"     => "example.com",
        ":path"          => "/",
        "content-length" => "5",
      }))
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :server)

    assert_nil connection.receive
    assert_equal [{1, Error::Code::PROTOCOL_ERROR}], reset_streams(output)
  end

  def test_sends_header_block_larger_than_max_frame_size_in_continuation_frames
    output = IO::Memory.new
    client = Connection.new(IO::Stapled.new(IO::Memory.new, output), :client)
    headers = HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
      "x-large"    => "a" * 60000, # 37500 bytes once huffman encoded
    }
    client.streams.create.send_headers(headers, Frame::Flags::END_STREAM)

    output.rewind
    frames = [] of {Frame::Type, Frame::Flags}
    sizes = [] of Int32
    while output.pos < output.size
      header = output.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      frames << {Frame::Type.new((header & 0xff).to_i), Frame::Flags.new(output.read_byte.not_nil!)}
      sizes << (header >> 8).to_i
      output.skip(4 + sizes.last) # stream id, payload
    end
    assert_equal [
      {Frame::Type::HEADERS, Frame::Flags::END_STREAM},
      {Frame::Type::CONTINUATION, Frame::Flags::None},
      {Frame::Type::CONTINUATION, Frame::Flags::END_HEADERS},
    ], frames
    assert_equal [16384, 16384], sizes[0, 2]
    assert_includes 1..16384, sizes.last

    output.rewind
    server = Connection.new(output, :server)
    frame = server.receive.not_nil!
    assert_equal headers, frame.stream.headers
  end

  def test_sends_header_block_larger_than_max_frame_size_on_open_stream
    output = IO::Memory.new
    client = Connection.new(IO::Stapled.new(IO::Memory.new, output), :client)
    headers = HTTP::Headers{
      ":method"    => "POST",
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
      "x-large"    => "a" * 30000,
    }
    stream = client.streams.create
    stream.send_headers(headers)
    assert_equal Stream::State::OPEN, stream.state

    output.rewind
    server = Connection.new(output, :server)
    frame = server.receive.not_nil!
    assert_equal headers, frame.stream.headers
    assert_equal Stream::State::OPEN, frame.stream.state
  end

  def test_sends_response_header_block_larger_than_max_frame_size
    request = HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
    })
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1, request)
    input.rewind
    output = IO::Memory.new
    server = Connection.new(IO::Stapled.new(input, output), :server)
    stream = server.receive.not_nil!.stream

    headers = HTTP::Headers{":status" => "204", "x-large" => "a" * 30000}
    stream.send_headers(headers, Frame::Flags::END_STREAM)
    assert_equal Stream::State::CLOSED, stream.state

    output.rewind
    client = Connection.new(output, :client)
    client.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    frame = client.receive.not_nil!
    assert_equal headers, frame.stream.headers
  end

  def test_ignores_frames_in_flight_after_resetting_many_streams
    input = IO::Memory.new
    write_frame(input, Frame::Type::SETTINGS, Frame::Flags::None, 0, Bytes[0, 3, 0, 0, 0x05, 0xdc]) # max_concurrent_streams=1500
    write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, "hello".to_slice)
    write_frame(input, Frame::Type::DATA, Frame::Flags::None, 2999, "hello".to_slice)
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)
    connection.receive

    # e.g. cancel every request in flight
    1500.times do
      connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL).send_rst_stream(Error::Code::CANCEL)
    end
    assert_nil connection.receive # stream 1
    assert_nil connection.receive # stream 2999
  end

  def test_stops_ignoring_frames_on_the_oldest_reset_streams
    input = IO::Memory.new
    write_frame(input, Frame::Type::DATA, Frame::Flags::None, 3, "hello".to_slice)
    write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, "hello".to_slice)
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)

    # remembers 1024 more reset streams than may be open at once: 100 for the
    # peer, no limit announced for us
    1125.times do
      connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL).send_rst_stream(Error::Code::CANCEL)
    end
    assert_nil connection.receive # stream 3

    # RFC 9113 section 5.1
    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::STREAM_CLOSED, error.code
  end

  def test_server_ignores_frames_in_flight_on_streams_it_reset
    encoder = HPACK::Encoder.new(indexing: HPACK::Indexing::ALWAYS, huffman: false)
    request = HTTP::Headers{
      ":method"    => "POST",
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
    }
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1, encoder.encode(request))
    # sent by the client before it received the RST_STREAM
    3.times { write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, Bytes.new(16384)) }
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1,
      encoder.encode(HTTP::Headers{"x-trailer" => "1"}))
    # refers to the dynamic table entry the trailers above added
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 3,
      encoder.encode(request.dup.tap { |headers| headers["x-trailer"] = "1" }))
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :server)
    stream1 = connection.receive.not_nil!.stream

    stream1.send_rst_stream(Error::Code::CANCEL)
    refute_same stream1, connection.streams.find(1), "stream 1 is still in the stream table"
    4.times { assert_nil connection.receive }

    frame = connection.receive.not_nil!
    assert_equal 3, frame.stream.id
    assert_equal "1", frame.stream.headers["x-trailer"]
    # the ignored DATA still counts against the connection window
    assert_equal [{0, DEFAULT_INITIAL_WINDOW_SIZE}], window_updates(output)
  end

  def test_server_ignores_frames_in_flight_on_a_stream_it_reset_below_the_last_one
    encoder = HPACK::Encoder.new(indexing: HPACK::Indexing::ALWAYS, huffman: false)
    request = HTTP::Headers{
      ":method"    => "POST",
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
    }
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1, encoder.encode(request))
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 3, encoder.encode(request))
    # sent by the client before it received the RST_STREAM on stream 1
    write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, Bytes.new(10))
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1,
      encoder.encode(HTTP::Headers{"x-trailer" => "1"}))
    # refers to the dynamic table entry the trailers above added
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 5,
      encoder.encode(request.dup.tap { |headers| headers["x-trailer"] = "1" }))
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :server)
    stream1 = connection.receive.not_nil!.stream
    connection.receive

    # e.g. an early response to stream 1 while stream 3 is open
    stream1.send_rst_stream(Error::Code::NO_ERROR)
    2.times { assert_nil connection.receive }

    frame = connection.receive.not_nil!
    assert_equal 5, frame.stream.id
    assert_equal "1", frame.stream.headers["x-trailer"]
  end

  def test_client_forgets_closed_streams_and_keeps_their_body
    connection, stream = client_closed_stream
    assert_equal Stream::State::CLOSED, stream.state

    forgotten = connection.streams.find(1)
    refute_same stream, forgotten, "stream 1 is still in the stream table"
    assert_equal Stream::State::CLOSED, forgotten.state
    # whoever holds the stream may still read the body
    assert_equal "hello", stream.data.gets_to_end
  end

  def test_client_treats_frames_on_forgotten_streams_as_closed
    connection, stream = client_closed_stream do |input|
      write_frame(input, Frame::Type::WINDOW_UPDATE, Frame::Flags::None, 1, Bytes[0, 0, 0, 1])
      write_frame(input, Frame::Type::RST_STREAM, Frame::Flags::None, 1, Bytes[0, 0, 0, 0])
      write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, "hello".to_slice)
    end
    refute_same stream, connection.streams.find(1), "stream 1 is still in the stream table"

    # WINDOW_UPDATE and RST_STREAM may follow the end of a stream (RFC 9113
    # section 5.1)
    assert_equal Frame::Type::WINDOW_UPDATE, connection.receive.not_nil!.type
    assert_equal Frame::Type::RST_STREAM, connection.receive.not_nil!.type

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::STREAM_CLOSED, error.code
  end

  def test_client_rejects_headers_on_forgotten_streams
    connection, stream = client_closed_stream do |input|
      write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1,
        HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}))
    end
    refute_same stream, connection.streams.find(1), "stream 1 is still in the stream table"

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::STREAM_CLOSED, error.code
  end

  # Receives a complete response to a GET request on stream 1, then gives
  # *input* to the block to append frames.
  private def client_closed_stream(&)
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}))
    write_frame(input, Frame::Type::DATA, Frame::Flags::END_STREAM, 1, "hello".to_slice)
    yield input
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)
    stream = connection.streams.create
    stream.send_headers(HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
    }, Frame::Flags::END_STREAM)
    2.times { connection.receive }
    {connection, stream}
  end

  private def client_closed_stream
    client_closed_stream { }
  end

  def test_server_forgets_closed_streams
    connection, output, stream = server_closed_stream { }
    refute_same stream, connection.streams.find(1), "stream 1 is still in the stream table"

    # the client must not retry the request: it was processed
    connection.close
    assert_equal [{1, Error::Code::NO_ERROR}], goaways(output)
  end

  def test_server_treats_frames_on_forgotten_streams_as_closed
    connection, _, stream = server_closed_stream do |input, encoder|
      write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 3, encoder.encode(REQUEST))
      write_frame(input, Frame::Type::WINDOW_UPDATE, Frame::Flags::None, 1, Bytes[0, 0, 0, 1])
      write_frame(input, Frame::Type::RST_STREAM, Frame::Flags::None, 1, Bytes[0, 0, 0, 0])
      write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, "hello".to_slice)
    end
    refute_same stream, connection.streams.find(1), "stream 1 is still in the stream table"
    assert_equal 3, connection.receive.not_nil!.stream.id

    # a lower stream identifier than the last one opened, but not idle
    assert_equal Frame::Type::WINDOW_UPDATE, connection.receive.not_nil!.type
    assert_equal Frame::Type::RST_STREAM, connection.receive.not_nil!.type

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::STREAM_CLOSED, error.code
  end

  def test_server_rejects_headers_on_forgotten_streams
    connection, _, stream = server_closed_stream do |input, encoder|
      write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1, encoder.encode(REQUEST))
    end
    refute_same stream, connection.streams.find(1), "stream 1 is still in the stream table"

    # not a new request on a reused stream identifier
    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::STREAM_CLOSED, error.code
  end

  def test_server_rejects_new_stream_below_the_last_stream_identifier
    encoder = HPACK::Encoder.new(huffman: false)
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 5, encoder.encode(REQUEST))
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 3, encoder.encode(REQUEST))
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :server)
    connection.receive

    # RFC 9113 section 5.1.1
    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code
  end

  private REQUEST = HTTP::Headers{
    ":method"    => "GET",
    ":scheme"    => "http",
    ":authority" => "example.com",
    ":path"      => "/",
  }

  # Receives a GET request on stream 1 and responds to it, then gives *input*
  # and the HPACK encoder to the block to append frames.
  private def server_closed_stream(&)
    encoder = HPACK::Encoder.new(huffman: false)
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1, encoder.encode(REQUEST))
    yield input, encoder
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :server)
    stream = connection.receive.not_nil!.stream
    stream.send_headers(HTTP::Headers{":status" => "204"}, Frame::Flags::END_STREAM)
    assert_equal Stream::State::CLOSED, stream.state
    {connection, output, stream}
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

  # Parses the RST_STREAM frames written to *io* as {stream_id, error_code}.
  private def reset_streams(io : IO::Memory)
    io.rewind
    resets = [] of {Int32, Error::Code}
    while io.pos < io.size
      header = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      size, type = header >> 8, header & 0xff
      io.skip(1) # flags
      stream_id = io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i32 & 0x7fffffff
      if type == Frame::Type::RST_STREAM.value
        resets << {stream_id, Error::Code.new(io.read_bytes(UInt32, IO::ByteFormat::BigEndian))}
      else
        io.skip(size)
      end
    end
    resets
  end

  # Parses the GOAWAY frames written to *io* as {last_stream_id, error_code}.
  private def goaways(io : IO::Memory)
    io.rewind
    frames = [] of {Int32, Error::Code}
    while io.pos < io.size
      header = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      size, type = header >> 8, header & 0xff
      io.skip(5) # flags, stream id
      if type == Frame::Type::GOAWAY.value
        last_stream_id = io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i32 & 0x7fffffff
        frames << {last_stream_id, Error::Code.new(io.read_bytes(UInt32, IO::ByteFormat::BigEndian))}
        io.skip(size - 8)
      else
        io.skip(size)
      end
    end
    frames
  end
end
