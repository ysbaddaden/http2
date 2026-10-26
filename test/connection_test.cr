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

  def test_client_disables_push
    output = IO::Memory.new
    client = Connection.new(IO::Stapled.new(IO::Memory.new, output), :client)
    client.write_settings

    output.rewind
    server = Connection.new(IO::Stapled.new(output, IO::Memory.new), :server)
    server.receive
    refute server.remote_settings.enable_push
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

  def test_client_skips_interim_responses
    input = IO::Memory.new
    encoder = HPACK::Encoder.new(huffman: false)
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      encoder.encode(HTTP::Headers{":status" => "100"}))
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      encoder.encode(HTTP::Headers{":status" => "103", "link" => "</style.css>; rel=preload"}))
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1,
      encoder.encode(HTTP::Headers{":status" => "200"}))
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)

    frames = Array.new(3) { connection.receive }
    assert_equal HTTP::Headers{":status" => "200"}, stream.headers
    assert_nil frames[0]
    assert_nil frames[1]
    assert_same stream, frames[2].try(&.stream)
    assert_empty stream.data.gets_to_end
  end

  def test_client_resets_stream_on_interim_response_with_end_stream
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "100"}))
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    stream = connection.streams.create(state: Stream::State::OPEN)

    frame = connection.receive
    assert_equal [{1, Error::Code::PROTOCOL_ERROR}], reset_streams(output)
    assert_nil frame
    assert_raises(IO::Error) { stream.data.gets_to_end }
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

  def test_rejects_header_block_larger_than_max_header_list_size
    payload = HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{
      ":method"    => "GET",
      ":scheme"    => "http",
      ":authority" => "example.com",
      ":path"      => "/",
      "x-large"    => "a" * 3000,
    })
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_STREAM, 1, payload[0, 1000])
    write_frame(input, Frame::Type::CONTINUATION, Frame::Flags::None, 1, payload[1000, 1000])
    write_frame(input, Frame::Type::CONTINUATION, Frame::Flags::END_HEADERS, 1, payload[2000..])
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :server)
    connection.local_settings.max_header_list_size = 2048

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code
  end

  def test_stops_reading_continuation_frames_past_max_header_list_size
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::None, 1, Bytes.new(1000))
    100.times { write_frame(input, Frame::Type::CONTINUATION, Frame::Flags::None, 1, Bytes.new(1000)) }
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)
    connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code
    # stopped past the default max_header_list_size (16384)
    assert input.pos < 20_000, "read #{input.pos} bytes"
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

  def test_send_data_waits_when_another_stream_took_the_connection_window
    input = IO::Memory.new
    write_frame(input, Frame::Type::WINDOW_UPDATE, Frame::Flags::None, 0, Bytes[0, 0, 0x40, 0])
    input.rewind
    output = IO::Memory.new
    connection = RacingConnection.new(IO::Stapled.new(input, output), :client)
    stream = connection.streams.create(state: Stream::State::OPEN)

    result = Channel(Exception?).new(1)
    spawn do
      stream.send_data("hello", Frame::Flags::END_STREAM)
      result.send(nil)
    rescue ex
      result.send(ex)
    end
    # the WINDOW_UPDATE must come after the sender lost the race
    select
    when connection.raced.receive
    when timeout(1.second)
      flunk "sender didn't consume the connection window"
    end
    connection.receive # WINDOW_UPDATE

    select
    when value = result.receive
      assert_nil value
    when timeout(1.second)
      flunk "sender is still blocked after WINDOW_UPDATE"
    end
    assert_equal [{1, Frame::Flags::END_STREAM, 5}], data_frames(output)
  end

  # Another stream takes the whole connection window between the sender's
  # window check and its own consumption, once; then signals `#raced`.
  private class RacingConnection < Connection
    getter raced = Channel(Nil).new(1)
    @race = true

    protected def consume_outbound_window_size(size)
      return super unless @race
      @race = false
      super(outbound_window_size)
      @raced.send(nil)
      0
    end
  end

  def test_send_data_gives_the_connection_window_back_when_the_stream_got_closed
    connection = ClosingConnection.new(IO::Stapled.new(IO::Memory.new, IO::Memory.new), :client)
    stream = connection.streams.create(state: Stream::State::OPEN)
    connection.closing = stream

    assert_raises(Error) { stream.send_data("hello") }
    # the DATA frame wasn't sent: its size is still available to other streams
    assert_equal DEFAULT_INITIAL_WINDOW_SIZE, connection.outbound_window_size
  end

  # Closes a stream (as if another fiber reset it) right after the stream
  # consumed the connection window to send DATA.
  private class ClosingConnection < Connection
    property closing : Stream?

    protected def consume_outbound_window_size(size)
      super.tap { closing.try(&.send_rst_stream(Error::Code::CANCEL)) }
    end
  end

  # Parses the DATA frames written to *io* as {stream_id, flags, size}.
  private def data_frames(io : IO::Memory)
    io.rewind
    frames = [] of {Int32, Frame::Flags, Int32}
    while io.pos < io.size
      header = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      size, type = (header >> 8).to_i, header & 0xff
      flags = Frame::Flags.new(io.read_byte.not_nil!)
      stream_id = io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i32 & 0x7fffffff
      frames << {stream_id, flags, size} if type == Frame::Type::DATA.value
      io.skip(size)
    end
    frames
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

  def test_rejects_uppercase_header_names
    {"X-Custom", "x-Custom", "x-customX"}.each do |name|
      payload = IO::Memory.new
      payload.write(HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{
        ":method"    => "GET",
        ":scheme"    => "http",
        ":authority" => "example.com",
        ":path"      => "/",
      }))
      # literal header field without indexing, new name (the encoder would
      # lowercase the name)
      payload.write_byte(0_u8)
      payload.write_byte(name.bytesize.to_u8)
      payload << name
      payload.write_byte(5_u8)
      payload << "value"
      connection = new_connection(:server, {
        Frame::Type::HEADERS,
        Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM,
        1,
        payload.to_slice,
      })

      error = begin
        connection.receive
        nil
      rescue ex : Error
        ex
      end
      assert_equal Error::Code::PROTOCOL_ERROR, error.try(&.code), "#{name} header"
    end
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

  def test_client_sends_stream_window_update_once_half_the_window_was_read
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}))
    3.times { write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, Bytes.new(16384)) }
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    4.times { connection.receive }

    stream.data.read_fully(Bytes.new(32767))
    assert_empty window_updates(output).select { |(id, _)| id == 1 }

    stream.data.read_fully(Bytes.new(1))
    assert_equal [{1, 32768}], window_updates(output).select { |(id, _)| id == 1 }
  end

  def test_client_sends_stream_window_update_once_the_buffered_data_was_read
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}))
    write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, Bytes.new(1000))
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    2.times { connection.receive }

    stream.data.read_fully(Bytes.new(999))
    assert_empty window_updates(output).select { |(id, _)| id == 1 }

    # the peer may be waiting for the window
    stream.data.read_fully(Bytes.new(1))
    assert_equal [{1, 1000}], window_updates(output).select { |(id, _)| id == 1 }
  end

  def test_client_sends_no_stream_window_update_once_the_body_was_received
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}))
    write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, Bytes.new(16384))
    write_frame(input, Frame::Type::DATA, Frame::Flags::END_STREAM, 1, Bytes.new(16384))
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    3.times { connection.receive }

    assert_equal 32768, stream.data.gets_to_end.bytesize
    assert_empty window_updates(output).select { |(id, _)| id == 1 }
  end

  def test_client_sends_initial_connection_window_update_for_large_window
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(IO::Memory.new, output), :client)
    connection.local_settings.initial_window_size = 1 << 20
    connection.write_settings

    assert_equal [{0, (1 << 20) - DEFAULT_INITIAL_WINDOW_SIZE}], window_updates(output)
  end

  def test_connection_window_size_is_configurable
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}))
    3.times { write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, Bytes.new(16384)) }
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    connection.local_window_size = 16 << 20
    connection.write_settings
    connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    4.times { connection.receive }

    assert_equal [{0, (16 << 20) - DEFAULT_INITIAL_WINDOW_SIZE}], window_updates(output)
  end

  def test_connection_window_update_never_exceeds_maximum_window_size
    input = IO::Memory.new
    2.times { write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, Bytes.new(16384)) }
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    2.times { connection.streams.create(state: Stream::State::OPEN) }
    # set once the streams exist, so their body buffers keep the default size
    connection.local_settings.initial_window_size = 1 << 30
    2.times { connection.receive }

    # the window grows to the maximum, not by twice the initial window size
    assert_equal [{0, MAXIMUM_WINDOW_SIZE - (DEFAULT_INITIAL_WINDOW_SIZE - 16384)}], window_updates(output)
  end

  def test_padded_data_counts_against_both_windows
    input = IO::Memory.new
    # 200 frames of 257 bytes: 1 byte of data, the Pad Length field and 255
    # bytes of padding
    200.times { write_padded_data_frame(input, 1, Bytes.new(1), 255) }
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    200.times { connection.receive }

    # the peer charged 200 * 257 bytes to both windows (RFC 9113 section
    # 6.9.1): the connection window passed the half-way mark, and the
    # padding goes back to the stream at once, since it isn't read
    updates = window_updates(output)
    assert_equal [{0, DEFAULT_INITIAL_WINDOW_SIZE}], updates.select { |(id, _)| id == 0 }
    assert_equal 200 * 256, updates.select { |(id, _)| id == 1 }.sum(&.[1])
    assert_equal 200, stream.data.size
  end

  def test_padding_of_data_ending_the_stream_isnt_given_back
    input = IO::Memory.new
    write_padded_data_frame(input, 1, "hello".to_slice, 10)
    write_padded_data_frame(input, 1, "world".to_slice, 20, Frame::Flags::END_STREAM)
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    2.times { connection.receive }

    # the Pad Length field and the padding of the first frame; the peer
    # can't send on the stream anymore after the second one
    assert_equal [{1, 11}], window_updates(output)
    assert_equal "helloworld", stream.data.gets_to_end
  end

  def test_rejects_invalid_pad_length_on_ignored_data
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}))
    # Pad Length 10 in a frame of 6 bytes
    write_frame(input, Frame::Type::DATA, Frame::Flags::PADDED, 1, Bytes[10, 0, 0, 0, 0, 0])
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    connection.receive
    stream.send_rst_stream(Error::Code::CANCEL)

    # RFC 9113 section 6.1
    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code
  end

  private def write_padded_data_frame(io, stream_id, data, pad_size, flags = Frame::Flags::None)
    payload = IO::Memory.new
    payload.write_byte(pad_size.to_u8)
    payload.write(data)
    payload.write(Bytes.new(pad_size))
    write_frame(io, Frame::Type::DATA, flags | Frame::Flags::PADDED, stream_id, payload.to_slice)
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

  def test_received_rst_stream_keeps_its_code_for_the_body_reader
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS,
      1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}),
    }
    reset_stream_frame = {Frame::Type::RST_STREAM, Frame::Flags::None, 1, Bytes[0, 0, 0, 2]} # INTERNAL_ERROR
    connection = new_connection(:client, headers_frame, reset_stream_frame)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    connection.receive
    assert_nil stream.received_reset_code

    # the reader may wake before or after #receive returns: the code is
    # known either way
    result = Channel(Error::Code? | String).new(1)
    spawn do
      result.send(stream.data.gets_to_end)
    rescue IO::Error
      result.send(stream.received_reset_code)
    end

    connection.receive

    select
    when value = result.receive
      assert_equal Error::Code::INTERNAL_ERROR, value
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
    assert_equal "hello", stream.data.gets_to_end
  end

  def test_received_goaway_reports_last_stream_id_and_error_code
    goaway_frame = {Frame::Type::GOAWAY, Frame::Flags::None, 0, Bytes[0, 0, 0, 3, 0, 0, 0, 2]} # last_stream_id=3, INTERNAL_ERROR
    connection = new_connection(:client, goaway_frame)

    frame = connection.receive.not_nil!
    assert_equal Frame::Type::GOAWAY, frame.type
    assert_equal 3, frame.last_stream_id
    assert_equal Error::Code::INTERNAL_ERROR, frame.error
  end

  def test_received_goaway_closes_streams_above_last_stream_id
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}))
    write_frame(input, Frame::Type::GOAWAY, Frame::Flags::None, 0, Bytes[0, 0, 0, 1, 0, 0, 0, 0]) # last_stream_id=1, NO_ERROR
    write_frame(input, Frame::Type::DATA, Frame::Flags::END_STREAM, 1, "hello".to_slice)
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)
    stream1 = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    stream3 = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    2.times { connection.receive }

    # the server didn't process stream 3: the request may be retried
    assert_equal Stream::State::CLOSED, stream3.state
    assert_raises(IO::Error) { stream3.data.gets_to_end }

    connection.receive
    assert_equal "hello", stream1.data.gets_to_end
  end

  def test_received_goaway_with_error_code_lets_active_streams_complete
    headers_frame = {
      Frame::Type::HEADERS,
      Frame::Flags::END_HEADERS,
      1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}),
    }
    goaway_frame = {Frame::Type::GOAWAY, Frame::Flags::None, 0, Bytes[0, 0, 0, 1, 0, 0, 0, 0xb]} # last_stream_id=1, ENHANCE_YOUR_CALM
    data_frame = {Frame::Type::DATA, Frame::Flags::END_STREAM, 1, "hello".to_slice}
    connection = new_connection(:client, headers_frame, goaway_frame, data_frame)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)

    3.times { connection.receive }
    assert_equal "hello", stream.data.gets_to_end
  end

  def test_received_goaway_refuses_new_streams
    goaway_frame = {Frame::Type::GOAWAY, Frame::Flags::None, 0, Bytes[0, 0, 0, 0, 0, 0, 0, 0]} # last_stream_id=0, NO_ERROR
    connection = new_connection(:client, goaway_frame)
    connection.receive

    error = assert_raises(Error) { connection.streams.create }
    assert_equal Error::Code::REFUSED_STREAM, error.code

    # the peer's GOAWAY doesn't close the connection: closing it does
    refute connection.closed?
  end

  def test_rejects_goaway_on_a_stream
    goaway_frame = {Frame::Type::GOAWAY, Frame::Flags::None, 1, Bytes[0, 0, 0, 0, 0, 0, 0, 0]}
    connection = new_connection(:server, goaway_frame)

    # RFC 9113 section 6.8
    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code
  end

  def test_rejects_goaway_shorter_than_8_bytes
    # last_stream_id without an error code, then a frame that follows
    goaway_frame = {Frame::Type::GOAWAY, Frame::Flags::None, 0, Bytes[0, 0, 0, 1]}
    ping_frame = {Frame::Type::PING, Frame::Flags::None, 0, Bytes.new(8)}
    connection = new_connection(:client, goaway_frame, ping_frame)

    # RFC 9113 sections 4.2 and 6.8
    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::FRAME_SIZE_ERROR, error.code
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

  def test_discards_data_received_after_the_body_was_closed
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200", "content-length" => "10"}))
    write_frame(input, Frame::Type::DATA, Frame::Flags::None, 1, "hello".to_slice)
    write_frame(input, Frame::Type::DATA, Frame::Flags::END_STREAM, 1, "world".to_slice)
    write_frame(input, Frame::Type::PING, Frame::Flags::None, 0, Bytes.new(8))
    input.rewind
    output = IO::Memory.new
    connection = Connection.new(IO::Stapled.new(input, output), :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    connection.receive

    # another fiber closed the body (e.g. reset the stream) while the
    # connection was receiving DATA for it: the payload is discarded
    stream.data.close
    2.times { connection.receive }
    assert_equal Frame::Type::PING, connection.receive.try(&.type)
    assert_empty reset_streams(output)
  end

  def test_closing_the_body_doesnt_wait_for_the_data_frame_being_received
    with_data_frame_half_received do |connection, stream|
      stream.data.close
    end
  end

  def test_closing_the_connection_doesnt_wait_for_the_data_frame_being_received
    with_data_frame_half_received do |connection, stream|
      connection.close
    end
  end

  # The peer sent half of a DATA frame of 100 bytes on stream 1, and the
  # connection waits for the rest in `receive`: the block must return at
  # once. Then the rest arrives: its payload is dropped, and the next frame
  # is received.
  private def with_data_frame_half_received(&block : Connection, Stream ->) : Nil
    local, remote = IO::Stapled.pipe
    connection = Connection.new(local, :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)

    received = Channel(Frame? | Exception).new(2)
    spawn do
      2.times { received.send(connection.receive) }
    rescue ex
      received.send(ex)
    end

    frame = IO::Memory.new
    write_frame(frame, Frame::Type::DATA, Frame::Flags::None, 1, Bytes.new(100))
    remote.write(frame.to_slice[0, 9 + 50])
    remote.flush
    sleep 50.milliseconds # let the connection wait for the rest of the frame

    done = Channel(Nil).new(1)
    spawn do
      block.call(connection, stream)
      done.send(nil)
    end
    select
    when done.receive
    when timeout(1.second)
      flunk "closing waits for the rest of the DATA frame"
    end

    remote.write(frame.to_slice[9 + 50..])
    write_frame(remote, Frame::Type::PING, Frame::Flags::None, 0, Bytes.new(8))
    remote.flush
    frames = Array.new(2) do
      select
      when value = received.receive
        raise value if value.is_a?(Exception)
        value
      when timeout(1.second)
        flunk "the connection doesn't receive frames anymore"
      end
    end
    assert_equal Frame::Type::PING, frames.last.try(&.type)
  ensure
    remote.try(&.close)
  end

  def test_accepts_frames_on_a_stream_reset_while_receiving_them
    connection = Connection.new(IO::Stapled.new(IO::Memory.new, IO::Memory.new), :client)
    # another fiber reset the stream once the connection checked it but
    # before the frame made the stream's state transition
    stream = Stream.new(connection, 1, state: Stream::State::CLOSED, reset_sent: true)
    stream.receiving(Frame.new(Frame::Type::DATA, stream))
    stream.receiving(Frame.new(Frame::Type::HEADERS, stream, Frame::Flags::END_STREAM))
    assert stream.state.closed?
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
    server.local_settings.max_header_list_size = 1 << 16
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
    server.local_settings.max_header_list_size = 1 << 16
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
    client.local_settings.max_header_list_size = 1 << 16
    client.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    frame = client.receive.not_nil!
    assert_equal headers, frame.stream.headers
  end

  def test_open_stream_sends_headers
    output = IO::Memory.new
    client = Connection.new(IO::Stapled.new(IO::Memory.new, output), :client)

    stream1 = client.open_stream(REQUEST, Frame::Flags::END_STREAM)
    assert_equal 1, stream1.id
    assert_equal Stream::State::HALF_CLOSED_LOCAL, stream1.state

    stream3 = client.open_stream(REQUEST)
    assert_equal 3, stream3.id
    assert_equal Stream::State::OPEN, stream3.state

    output.rewind
    server = Connection.new(output, :server)
    2.times do |i|
      frame = server.receive.not_nil!
      assert_equal 2 * i + 1, frame.stream.id
      assert_equal REQUEST, frame.stream.headers
    end
  end

  def test_open_stream_sends_streams_in_order
    output = YieldingWriter.new
    client = Connection.new(IO::Stapled.new(IO::Memory.new, output), :client)
    headers = REQUEST.dup.tap { |h| h["x-large"] = "a" * 30000 } # needs CONTINUATION frames
    done = Channel(Int32 | Exception).new(10)

    10.times do
      spawn do
        done.send(client.open_stream(headers, Frame::Flags::END_STREAM).id)
      rescue ex
        done.send(ex)
      end
    end
    ids = Array.new(10) { done.receive.as(Int32) }
    assert_equal (1..19).step(2).to_a, ids.sort

    # increasing stream identifiers, header blocks not interleaved
    output.rewind
    server = Connection.new(output, :server)
    server.local_settings.max_header_list_size = 1 << 16
    10.times do |i|
      frame = server.receive.not_nil!
      assert_equal 2 * i + 1, frame.stream.id
      assert_equal headers, frame.stream.headers
    end
  end

  def test_client_accepts_response_to_head_request_with_content_length_on_open_stream
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200", "content-length" => "1000"}))
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)
    stream = connection.open_stream(REQUEST.dup.tap { |h| h[":method"] = "HEAD" }, Frame::Flags::END_STREAM)

    frame = connection.receive.not_nil!
    assert_same stream, frame.stream
    assert_empty stream.data.gets_to_end
  end

  # Yields to other fibers on every write, as a socket would when its buffer
  # is full.
  private class YieldingWriter < IO::Memory
    def write(slice : Bytes) : Nil
      Fiber.yield
      super
    end
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
