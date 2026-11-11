require "./test_helper"
require "../src/http2"

class HTTP2::ConnectionTest < Minitest::Test
  def test_end_headers_payload_excludes_priority_padding_and_next_frame
    connection = new_connection(:client,
      {Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::PADDED | Frame::Flags::PRIORITY,
       2, Bytes[2, 0, 0, 0, 0, 0, 0x88, 0, 0]},
      {Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 4, Bytes[0x89]})

    assert_equal "200", connection.receive.not_nil!.stream.headers[":status"]
    assert_equal "204", connection.receive.not_nil!.stream.headers[":status"]
  end

  def test_rejects_oversized_compressed_headers_before_reading_payload
    io = IO::Memory.new
    write_frame(io, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 2, Bytes.new(101))
    io.rewind
    connection = Connection.new(io, :client)
    connection.local_settings.max_header_list_size = 100

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::ENHANCE_YOUR_CALM, error.code
    assert_equal 9, io.pos
  end

  def test_rejects_oversized_continuation_before_reading_payload
    io = IO::Memory.new
    write_frame(io, Frame::Type::HEADERS, Frame::Flags::None, 2, Bytes.new(60))
    write_frame(io, Frame::Type::CONTINUATION, Frame::Flags::END_HEADERS, 2, Bytes.new(41))
    io.rewind
    connection = Connection.new(io, :client)
    connection.local_settings.max_header_list_size = 100
    connection.remote_settings.max_header_list_size = 1000

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::ENHANCE_YOUR_CALM, error.code
    assert_equal 78, io.pos
  end

  def test_compressed_headers_at_max_header_list_size
    # Empty table size updates add compressed bytes without adding header fields.
    payload = Bytes.new(100, 0x20_u8)
    payload[99] = 0x88_u8 # :status=200
    connection = new_connection(:client,
      {Frame::Type::HEADERS, Frame::Flags::None, 2, payload[0, 60]},
      {Frame::Type::CONTINUATION, Frame::Flags::END_HEADERS, 2, payload[60, 40]})
    connection.local_settings.max_header_list_size = 100

    assert_equal "200", connection.receive.not_nil!.stream.headers[":status"]
  end

  def test_decoded_headers_respect_local_max_header_list_size
    headers = HTTP::Headers{":status" => "200", "x-name" => ["é", "é"]}
    payload = HPACK::Encoder.new(huffman: false).encode(headers)
    headers_frame = {Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 2, payload}

    # :status=200 (42 bytes), plus two x-name=é fields (40 bytes each).
    connection = new_connection(:client, headers_frame)
    connection.local_settings.max_header_list_size = 121
    connection.remote_settings.max_header_list_size = 1000

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::ENHANCE_YOUR_CALM, error.code

    connection = new_connection(:client, headers_frame)
    connection.local_settings.max_header_list_size = 122
    connection.remote_settings.max_header_list_size = 0
    assert_equal headers, connection.receive.not_nil!.stream.headers
  end

  def test_decoded_headers_respect_default_max_header_list_size
    headers = HTTP::Headers{":status" => "200", "x-large" => "a" * 16384}
    payload = HPACK::Encoder.new(huffman: true).encode(headers)
    connection = new_connection(:client, {Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 2, payload})

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::ENHANCE_YOUR_CALM, error.code
  end

  def test_decoded_trailers_respect_max_header_list_size
    encoder = HPACK::Encoder.new(huffman: true)
    headers = encoder.encode(HTTP::Headers{":status" => "200"})
    trailers = encoder.encode(HTTP::Headers{"x-trailer" => "a" * 100})

    connection = new_connection(:client,
      {Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 2, headers},
      {Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 2, trailers})
    connection.local_settings.max_header_list_size = 100
    connection.receive

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::ENHANCE_YOUR_CALM, error.code
  end

  def test_settings_window_overflow_removes_streams_during_iteration
    settings = {Frame::Type::SETTINGS, Frame::Flags::None, 0, Bytes[0, 4, 0, 1, 0, 0]}
    connection = new_connection(:client, settings)

    overflowing = Array.new(32) do
      stream = connection.streams.create(state: Stream::State::OPEN)
      stream.increment_outbound_window_size(MAXIMUM_WINDOW_SIZE - DEFAULT_INITIAL_WINDOW_SIZE)
      stream
    end
    survivor = connection.streams.create(state: Stream::State::OPEN)

    connection.receive

    overflowing.each do |stream|
      assert_equal Stream::State::CLOSED, stream.state
      refute connection.streams.has_key?(stream.id)
    end
    assert_equal Stream::State::OPEN, survivor.state
    assert_equal DEFAULT_INITIAL_WINDOW_SIZE + 1, survivor.@outbound_window_size
  end

  def test_closed_streams_are_removed_on_a_long_lived_connection
    connection = new_connection(:client)

    100.times do
      stream = connection.streams.create(state: Stream::State::OPEN)
      stream.send_rst_stream(Error::Code::CANCEL)
    end
    assert_equal 0, connection.streams.size

    assert_equal Stream::State::CLOSED, connection.streams.find(1).state
    assert_equal 0, connection.streams.size
  end

  def test_received_reset_removes_stream_without_forgetting_last_remote_id
    reset = {Frame::Type::RST_STREAM, Frame::Flags::None, 3, Bytes[0, 0, 0, 0]}
    connection = new_connection(:server, reset, reset)
    stream = connection.streams.find(3)
    stream.receiving(Frame.new(Frame::Type::HEADERS, stream))

    assert connection.receive.not_nil!.stream.same?(stream)
    assert_equal 0, connection.streams.size
    assert_equal 3, connection.streams.last_stream_id
    assert_equal Stream::State::CLOSED, connection.receive.not_nil!.stream.state
    assert_equal 0, connection.streams.size
  end

  def test_end_stream_in_both_directions_removes_stream
    data = {Frame::Type::DATA, Frame::Flags::END_STREAM, 1, Bytes[42]}

    connection = new_connection(:client, data)
    stream = connection.streams.create(state: Stream::State::OPEN)
    stream.sending(Frame.new(Frame::Type::DATA, stream, Frame::Flags::END_STREAM))

    assert connection.receive.not_nil!.stream.same?(stream)
    assert_equal 0, connection.streams.size
    assert_equal "*", stream.data.gets_to_end
  end

  def test_control_frames_for_implicitly_closed_streams_do_not_retain_streams
    window_update = {Frame::Type::WINDOW_UPDATE, Frame::Flags::None, 1, Bytes[0, 0, 0, 1]}
    reset = {Frame::Type::RST_STREAM, Frame::Flags::None, 1, Bytes[0, 0, 0, 0]}

    connection = new_connection(:server, window_update, reset)
    connection.streams.find(3)
    connection.local_settings.max_concurrent_streams = 0

    first = connection.receive.not_nil!.stream
    second = connection.receive.not_nil!.stream
    assert_equal Stream::State::CLOSED, first.state
    assert_equal Stream::State::CLOSED, second.state
    refute first.same?(second)
  end

  def test_control_frames_on_idle_streams_are_protocol_errors
    connection = new_connection(:server, {Frame::Type::WINDOW_UPDATE, Frame::Flags::None, 1, Bytes[0, 0, 0, 1]})
    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code

    connection = new_connection(:server, {Frame::Type::RST_STREAM, Frame::Flags::None, 1, Bytes[0, 0, 0, 1]})
    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code
  end

  def test_window_update_on_closed_local_stream_is_ignored
    update = {Frame::Type::WINDOW_UPDATE, Frame::Flags::None, 1, Bytes[0x7f, 0xff, 0xff, 0xff]}
    connection = new_connection(:client, update)
    stream = connection.streams.create(state: Stream::State::OPEN)
    stream.sending(Frame.new(Frame::Type::RST_STREAM, stream))

    frame = connection.receive.not_nil!
    assert_equal Stream::State::CLOSED, frame.stream.state
    refute frame.stream.same?(stream)
    assert_equal 0, connection.streams.size
  end

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

  def test_trailers_after_empty_body
    [nil, Bytes.empty, Bytes[42]].each do |body|
      encoder = HPACK::Encoder.new(huffman: false)
      headers = encoder.encode(HTTP::Headers{":status" => "200"})
      trailers = encoder.encode(HTTP::Headers{"x-trailer" => "value"})
      io = IO::Memory.new
      write_frame(io, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 2, headers)
      write_frame(io, Frame::Type::DATA, Frame::Flags::None, 2, body) if body
      write_frame(io, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 2, trailers)
      io.rewind
      connection = Connection.new(io, :client)
      stream = connection.receive.not_nil!.stream
      connection.receive if body
      connection.receive

      assert_equal HTTP::Headers{"x-trailer" => "value"}, stream.trailers?
      assert_equal HTTP::Headers{":status" => "200"}, stream.headers
      assert_equal body.try(&.size) || 0, stream.data.gets_to_end.bytesize
    end
  end

  def test_informational_response_precedes_final_headers_and_trailers
    encoder = HPACK::Encoder.new(huffman: false)
    informational = encoder.encode(HTTP::Headers{":status" => "103", "link" => "</style.css>"})
    headers = encoder.encode(HTTP::Headers{":status" => "200"})
    trailers = encoder.encode(HTTP::Headers{"x-trailer" => "value"})

    [1, 2].each do |stream_id|
      connection = new_connection(:client,
        {Frame::Type::HEADERS, Frame::Flags::END_HEADERS, stream_id, informational},
        {Frame::Type::HEADERS, Frame::Flags::END_HEADERS, stream_id, headers},
        {Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, stream_id, trailers})
      connection.streams.create if stream_id.odd?

      stream = connection.receive.not_nil!.stream
      assert_equal "103", stream.headers[":status"]

      connection.receive
      assert_equal HTTP::Headers{":status" => "200"}, stream.headers
      assert_nil stream.trailers?

      connection.receive
      assert_equal HTTP::Headers{"x-trailer" => "value"}, stream.trailers?
    end
  end

  def test_rejects_trailers_without_end_stream_after_empty_body
    encoder = HPACK::Encoder.new(huffman: false)
    headers = encoder.encode(HTTP::Headers{":status" => "200"})
    trailers = encoder.encode(HTTP::Headers{"x-trailer" => "value"})
    connection = new_connection(:client,
      {Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 2, headers},
      {Frame::Type::DATA, Frame::Flags::None, 2, Bytes.empty},
      {Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 2, trailers})
    connection.receive
    connection.receive

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code
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
end
