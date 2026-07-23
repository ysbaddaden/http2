require "./test_helper"
require "../src/connection"

module HTTP2
  class ConnectionTest < Minitest::Test
    def test_rst_stream_exposes_error_code
      headers = HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{
        ":status" => "200",
      })
      io = IO::Memory.new(
        raw_frame(Frame::Type::HEADERS, Frame::Flags::END_HEADERS, 1, headers) +
        raw_frame(Frame::Type::RST_STREAM, Frame::Flags::None, 1, Bytes[0, 0, 0, 7])
      )
      connection = Connection.new(io, Connection::Type::CLIENT)

      connection.receive
      frame = connection.receive.not_nil!

      assert_equal Frame::Type::RST_STREAM, frame.type
      assert_equal Error::Code::REFUSED_STREAM, frame.reset_error_code
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
