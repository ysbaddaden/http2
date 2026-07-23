require "./test_helper"
require "../src/connection"

module HTTP2
  class ConnectionTest < Minitest::Test
    def test_headers_with_end_stream_closes_empty_body
      headers = HPACK::Encoder.new(huffman: false).encode(HTTP::Headers{
        ":status" => "204",
      })
      io = IO::Memory.new(raw_frame(Frame::Type::HEADERS, Frame::Flags::END_HEADERS | Frame::Flags::END_STREAM, 1, headers))
      connection = Connection.new(io, Connection::Type::CLIENT)

      frame = connection.receive.not_nil!
      async { assert_equal "", frame.stream.data.gets_to_end }
      wait(100.milliseconds)
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
