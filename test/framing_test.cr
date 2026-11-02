require "./test_helper"
require "../src/http2"

# How a connection reads frames: SETTINGS acknowledgements, padding, unused
# flags, unknown frame types and the largest SETTINGS values.
class HTTP2::FramingTest < Minitest::Test
  include TestHelpers

  REQUEST = HTTP::Headers{
    ":method"    => "GET",
    ":scheme"    => "http",
    ":authority" => "example.com",
    ":path"      => "/",
  }

  # Reads one byte at a time, as a socket may.
  class ShortReader < IO
    def initialize(@io : IO)
    end

    def read(slice : Bytes) : Int32
      return 0 if slice.empty?
      @io.read(slice[0, 1])
    end

    def write(slice : Bytes) : Nil
    end
  end

  def test_settings_ack_with_a_payload_is_a_frame_size_error
    connection = receiving do |io|
      write_frame(io, Frame::Type::SETTINGS, Frame::Flags::END_STREAM, 0, Bytes[0, 3, 0, 0, 0, 1])
    end
    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::FRAME_SIZE_ERROR, error.code
  end

  def test_empty_settings_ack_is_followed_by_the_next_frame
    connection = receiving do |io|
      write_frame(io, Frame::Type::SETTINGS, Frame::Flags::END_STREAM, 0)
      write_frame(io, Frame::Type::PING, Frame::Flags::None, 0, Bytes.new(8))
    end
    assert connection.receive.try(&.type.settings?)
    assert connection.receive.try(&.type.ping?)
  end

  def test_padded_headers_followed_by_continuation
    # GET http "/" split after the first byte, with one byte of padding
    connection = receiving do |io|
      write_frame(io, Frame::Type::HEADERS, Frame::Flags::PADDED | Frame::Flags::END_STREAM, 1, Bytes[0x01, 0x82, 0x00])
      write_frame(io, Frame::Type::CONTINUATION, Frame::Flags::END_HEADERS, 1, Bytes[0x86, 0x84, 0x41, 0x01, 0x78])
    end
    headers = connection.receive.not_nil!.stream.headers
    assert_equal "GET", headers[":method"]
    assert_equal "/", headers[":path"]
  end

  def test_padding_with_several_continuations
    block = HPACK::Encoder.new(huffman: false).encode(REQUEST)
    connection = receiving do |io|
      payload = IO::Memory.new
      payload.write_byte(5_u8)
      payload.write(block[0, 2])
      payload.write(Bytes.new(5))
      write_frame(io, Frame::Type::HEADERS, Frame::Flags::PADDED | Frame::Flags::END_STREAM, 1, payload.to_slice)
      write_frame(io, Frame::Type::CONTINUATION, Frame::Flags::None, 1, block[2, 3])
      write_frame(io, Frame::Type::CONTINUATION, Frame::Flags::END_HEADERS, 1, block[5..])
      write_frame(io, Frame::Type::PING, Frame::Flags::None, 0, Bytes.new(8))
    end
    assert_equal REQUEST, connection.receive.not_nil!.stream.headers
    assert connection.receive.try(&.type.ping?)
  end

  def test_padded_push_promise_followed_by_continuation
    block = HPACK::Encoder.new(huffman: false).encode(REQUEST)
    input = IO::Memory.new
    payload = IO::Memory.new
    payload.write_byte(3_u8)
    payload.write_bytes(2_u32, IO::ByteFormat::BigEndian)
    payload.write(block[0, 1])
    payload.write(Bytes.new(3))
    write_frame(input, Frame::Type::PUSH_PROMISE, Frame::Flags::PADDED, 1, payload.to_slice)
    write_frame(input, Frame::Type::CONTINUATION, Frame::Flags::END_HEADERS, 1, block[1..])
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)
    connection.local_settings.enable_push = true
    connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)

    frame = connection.receive.not_nil!
    assert_equal REQUEST, frame.promised_stream.headers
  end

  def test_unused_end_stream_bit_doesnt_close_a_half_closed_stream
    {
      {Frame::Type::WINDOW_UPDATE, Bytes[0, 0, 0, 1]},
      {Frame::Type::PRIORITY, Bytes[0, 0, 0, 0, 15]},
    }.each do |type, payload|
      connection = receiving do |io|
        write_frame(io, Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1,
          HPACK::Encoder.new(huffman: false).encode(REQUEST))
        write_frame(io, type, Frame::Flags::END_STREAM, 1, payload)
      end
      stream = connection.receive.not_nil!.stream
      assert_equal Stream::State::HALF_CLOSED_REMOTE, stream.state
      connection.receive
      assert_equal Stream::State::HALF_CLOSED_REMOTE, stream.state, type.to_s
    end
  end

  def test_unused_end_stream_bit_on_a_sent_frame_doesnt_close_the_stream
    connection = receiving { }
    stream = connection.streams.find(1)
    stream.receiving(Frame.new(Frame::Type::HEADERS, stream, Frame::Flags::END_STREAM))
    stream.sending(Frame.new(Frame::Type::WINDOW_UPDATE, stream, Frame::Flags::END_STREAM))
    assert_equal Stream::State::HALF_CLOSED_REMOTE, stream.state
    stream.sending(Frame.new(Frame::Type::DATA, stream, Frame::Flags::END_STREAM))
    assert_equal Stream::State::CLOSED, stream.state
  end

  def test_end_stream_on_data_still_closes_a_half_closed_stream
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1,
      HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{":status" => "200"}))
    write_frame(input, Frame::Type::DATA, Frame::Flags::END_STREAM, 1, "ok".to_slice)
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)
    stream = connection.streams.create(state: Stream::State::HALF_CLOSED_LOCAL)
    connection.receive
    connection.receive
    assert_equal Stream::State::CLOSED, stream.state
  end

  def test_unknown_frame_type_on_an_unopened_stream_is_ignored
    input = IO::Memory.new
    write_raw_frame(input, 0xf0, 0, 1, Bytes[1, 2, 3])
    write_frame(input, Frame::Type::PING, Frame::Flags::None, 0, Bytes.new(8))
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :client)

    frame = connection.receive.not_nil!
    assert_equal Bytes[1, 2, 3], frame.payload
    assert connection.receive.try(&.type.ping?)
    # no stream was opened
    assert_equal 0, connection.streams.active_count(:client)
  end

  def test_unknown_frame_type_is_read_in_full_from_a_short_reading_io
    input = IO::Memory.new
    write_raw_frame(input, 0xf0, 0, 0, Bytes[1, 2, 3])
    write_frame(input, Frame::Type::PING, Frame::Flags::None, 0, Bytes.new(8))
    input.rewind
    connection = Connection.new(IO::Stapled.new(ShortReader.new(input), IO::Memory.new), :server)

    connection.receive
    assert connection.receive.try(&.type.ping?)
  end

  def test_unknown_frame_type_in_a_header_block_is_a_protocol_error
    block = HPACK::Encoder.new(huffman: false).encode(REQUEST)
    input = IO::Memory.new
    write_frame(input, Frame::Type::HEADERS, Frame::Flags::END_STREAM, 1, block[0, 2])
    write_raw_frame(input, 0xf0, 0, 1, Bytes[1])
    write_frame(input, Frame::Type::CONTINUATION, Frame::Flags::END_HEADERS, 1, block[2..])
    input.rewind
    connection = Connection.new(IO::Stapled.new(input, IO::Memory.new), :server)

    error = assert_raises(Error) { connection.receive }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code
  end

  def test_accepts_the_largest_settings_values
    settings = Settings.new
    settings.initial_window_size = Int32::MAX
    settings.max_frame_size = 2**24 - 1
    assert_equal Int32::MAX, settings.initial_window_size
    assert_equal 2**24 - 1, settings.max_frame_size
  end

  def test_rejects_settings_values_above_the_largest
    settings = Settings.new
    error = assert_raises(Error) { settings.initial_window_size = 2_i64**31 }
    assert_equal Error::Code::FLOW_CONTROL_ERROR, error.code
    error = assert_raises(Error) { settings.max_frame_size = 2**24 }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code
    error = assert_raises(Error) { settings.max_frame_size = 2**14 - 1 }
    assert_equal Error::Code::PROTOCOL_ERROR, error.code
  end

  def test_receives_the_largest_settings_values
    payload = IO::Memory.new
    payload.write_bytes(0x4_u16, IO::ByteFormat::BigEndian)
    payload.write_bytes(Int32::MAX.to_u32, IO::ByteFormat::BigEndian)
    payload.write_bytes(0x5_u16, IO::ByteFormat::BigEndian)
    payload.write_bytes((2_u32**24) - 1, IO::ByteFormat::BigEndian)
    connection = receiving do |io|
      write_frame(io, Frame::Type::SETTINGS, Frame::Flags::None, 0, payload.to_slice)
    end
    connection.receive
    assert_equal Int32::MAX, connection.remote_settings.initial_window_size
    assert_equal 2**24 - 1, connection.remote_settings.max_frame_size
  end

  # A server connection that receives the frames the block writes.
  private def receiving(&) : Connection
    input = IO::Memory.new
    yield input
    input.rewind
    Connection.new(IO::Stapled.new(input, IO::Memory.new), :server)
  end

  private def write_raw_frame(io, type : Int, flags : Int, stream_id : Int, payload : Bytes) : Nil
    io.write_bytes((payload.size.to_u32 << 8) | type.to_u32, IO::ByteFormat::BigEndian)
    io.write_byte(flags.to_u8)
    io.write_bytes(stream_id.to_u32, IO::ByteFormat::BigEndian)
    io.write(payload)
  end
end
