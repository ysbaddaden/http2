require "./test_helper"
require "../src/connection"

module HTTP2
  class ConnectionTest < Minitest::Test
    def test_client_respects_server_advertised_max_concurrent_streams
      io = io_with(max_concurrent_streams_frame(1))
      connection = Connection.new(io, Connection::Type::CLIENT)
      connection.receive

      stream = connection.streams.create(state: Stream::State::OPEN)
      assert_equal 1, stream.id

      error = assert_raises(Error) { connection.streams.create }
      assert_equal Error::Code::REFUSED_STREAM, error.code
    end

    def test_server_respects_client_advertised_max_concurrent_streams
      io = io_with(max_concurrent_streams_frame(1))
      connection = Connection.new(io, Connection::Type::SERVER)
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
      io = IO::Memory.new(
        raw_frame(Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1, headers) +
        raw_frame(Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 3, headers)
      )
      connection = Connection.new(io, Connection::Type::SERVER)
      connection.local_settings.max_concurrent_streams = 1

      connection.receive
      error = assert_raises(Error) { connection.receive }
      assert_equal Error::Code::REFUSED_STREAM, error.code
    end

    private def max_concurrent_streams_frame(value)
      raw_frame(Frame::Type::SETTINGS, Frame::Flags::None, 0, Bytes[0, 3, 0, 0, 0, value.to_u8])
    end

    private def io_with(bytes)
      IO::Memory.new.tap do |io|
        io.write(bytes)
        io.rewind
      end
    end

    private def raw_frame(type, flags, stream_id, payload = Bytes.empty)
      frame = IO::Memory.new
      frame.write_byte(((payload.size >> 16) & 0xff).to_u8)
      frame.write_byte(((payload.size >> 8) & 0xff).to_u8)
      frame.write_byte((payload.size & 0xff).to_u8)
      frame.write_byte(type.value.to_u8)
      frame.write_byte(flags.value.to_u8)
      frame.write_byte(((stream_id >> 24) & 0x7f).to_u8)
      frame.write_byte(((stream_id >> 16) & 0xff).to_u8)
      frame.write_byte(((stream_id >> 8) & 0xff).to_u8)
      frame.write_byte((stream_id & 0xff).to_u8)
      frame.write(payload)
      frame.to_slice
    end
  end
end
