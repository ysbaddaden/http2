require "./test_helper"
require "../src/http2"

class HTTP2::ConnectionTest < Minitest::Test
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
end
