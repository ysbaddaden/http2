require "./test_helper"
require "../src/slice_reader"

module HTTP2
  class SliceReaderTest < Minitest::Test
    def slice(*bytes)
      Slice(UInt8).new(bytes.size) { |i| bytes[i].to_u8 }
    end

    def new_reader
      SliceReader.new(slice(1, 2, 3, 4))
    end

    def reader
      @reader ||= new_reader
    end

    def test_read
      refute reader.done?
      assert_equal slice(1), reader.read(1)
      assert_equal slice(2, 3, 4), reader.read(3)
      assert reader.done?
      assert_raises(IndexError) { reader.read(1) }
    end

    def test_read_byte
      refute reader.done?
      assert_equal 1_u8, reader.read_byte
      assert_equal 2_u8, reader.read_byte
      assert_equal 3_u8, reader.read_byte
      assert_equal 4_u8, reader.read_byte
      assert reader.done?
      assert_raises(IndexError) { reader.read_byte }
    end

    def test_read_bytes
      if IO::ByteFormat::SystemEndian == IO::ByteFormat::LittleEndian
        reader = new_reader
        assert_equal 0x0102, reader.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        assert_equal 0x0304, reader.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        assert reader.done?

        reader = new_reader
        assert_equal 0x0201, reader.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        assert_equal 0x0403, reader.read_bytes(UInt16, IO::ByteFormat::LittleEndian)

        assert_equal 0x01020304, new_reader.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        assert_equal 0x04030201, new_reader.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      else
        reader = new_reader
        assert_equal 0x0201, reader.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        assert_equal 0x0403, reader.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        assert reader.done?

        reader = new_reader
        assert_equal 0x0102, reader.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        assert_equal 0x0304, reader.read_bytes(UInt16, IO::ByteFormat::LittleEndian)

        assert_equal 0x04030201, new_reader.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        assert_equal 0x01020304, new_reader.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      end
    end
  end
end
