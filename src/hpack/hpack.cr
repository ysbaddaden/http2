require "http/headers"
require "./huffman"
require "./static_table"
require "./dynamic_table"

module HTTP2
  module HPACK
    class Error < Exception
    end

    class SliceReader
      getter offset : Int32
      getter bytes : Slice(UInt8)

      def initialize(@bytes : Slice(UInt8))
        @offset = 0
      end

      def done?
        offset >= bytes.size
      end

      def current_byte
        bytes[offset]
      end

      def read_byte
        current_byte.tap { @offset += 1 }
      end

      def read(count)
        bytes[offset, count].tap { @offset += count }
      end
    end

    class Decoder
      private getter! reader : SliceReader
      getter table : DynamicTable

      def initialize(max_table_size = 4096)
        @table = DynamicTable.new(max_table_size)
      end

      def decode(bytes)
        @reader = SliceReader.new(bytes)
        headers = HTTP::Headers.new

        until reader.done?
          if reader.current_byte.bit(7) == 1           # 1.......  indexed
            index = integer(7)
            raise Error.new("invalid index: 0") if index == 0
            headers.add(*indexed(index))

          elsif reader.current_byte.bit(6) == 1        # 01......  literal with incremental indexing
            index = integer(6)
            name = index == 0 ? string : indexed(index).first
            value = string
            headers.add(name, value)
            table.add(name, value)

          elsif reader.current_byte.bit(5) == 1        # 001.....  table max size update
            table.resize(integer(5))

          elsif reader.current_byte.bit(4) == 1        # 0001....  literal without indexing
            index = integer(4)
            name = index == 0 ? string : indexed(index).first
            headers.add(name, string)

          else                                         # 0000....  literal never indexed
            index = integer(4)
            name = index == 0 ? string : indexed(index).first
            headers.add(name, string)
            # TODO: retain the never_indexed property into the header definition
          end
        end

        headers
      end

      protected def indexed(index)
        if index < STATIC_TABLE_SIZE
          return STATIC_TABLE[index - 1]
        end

        if header = table[index - STATIC_TABLE_SIZE - 1]?
          return header
        end

        raise Error.new("invalid index: #{index}")
      end

      protected def integer(n)
        integer = reader.read_byte & (0xff >> (8 - n))
        n2 = 2 ** n - 1
        return integer.to_i if integer < n2

        loop do |m|
          # TODO: raise if integer grows over limit
          byte = reader.read_byte
          integer = integer + (byte & 127) * 2 ** (m * 7)
          break unless byte.bit(7) == 1
        end

        integer.to_i
      end

      protected def string
        huffman = reader.current_byte.bit(7) == 1
        length = integer(7)
        bytes = reader.read(length)

        if huffman
          HPACK.huffman.decode(bytes)
        else
          String.new(bytes)
        end
      end
    end
  end

  #class Encoder
  #  def self.encode_integer(integer, n)
  #    n2 = 2 ** n - 1

  #    if integer <= n2
  #      return Slice(UInt8).new(1) { integer.to_u8 }
  #    end

  #    io = MemoryIO.new(3)
  #    io.write_byte n2.to_u8
  #    integer -= n2

  #    while integer >= 128
  #      io.write_byte ((integer % 128) + 128).to_u8
  #      integer /= 128
  #    end

  #    io.write_byte integer.to_u8
  #    io.to_slice
  #  end
  #end
end
