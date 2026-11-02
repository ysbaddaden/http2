require "../core_ext/http_headers"
require "./huffman"
require "./static_table"
require "./dynamic_table"
require "../slice_reader"

module HTTP
  struct Headers
    def each_key(&)
      @hash.each_key { |key| yield key.name }
    end
  end
end

module HTTP2
  module HPACK
    @[Flags]
    enum Indexing : UInt8
      INDEXED = 128_u8
      ALWAYS  =  64_u8
      NEVER   =  16_u8
      NONE    =   0_u8
    end

    class Error < Exception
    end

    # The decoded header list is larger than the limit given to
    # `Decoder#decode`.
    class ListSizeError < Error
    end

    # A decoded field has a name or a value that `HTTP::Headers` refuses:
    # the message is malformed, but the block was decoded in full, so the
    # decoder is still in sync.
    class InvalidFieldError < Error
    end

    # The largest integer the decoder accepts (RFC 7541 section 5.1 lets an
    # implementation limit them): larger ones are a decoding error.
    MAX_INTEGER = Int32::MAX

    class Decoder
      private getter! reader : SliceReader
      getter table : DynamicTable
      property max_table_size : Int32

      def initialize(@max_table_size = 4096)
        @table = DynamicTable.new(@max_table_size)
      end

      # Decodes a header block into *headers*. With *max_size*, raises
      # `ListSizeError` once the decoded list is larger: the size of the
      # names and values plus 32 bytes per field, as SETTINGS_MAX_HEADER_LIST_SIZE
      # counts it (RFC 9113 section 6.5.2), indexed fields included.
      def decode(bytes, headers = HTTP::Headers.new, max_size : Int32? = nil)
        @reader = SliceReader.new(bytes)
        # a dynamic table size update may only come before the first field
        # (RFC 7541 section 4.2)
        decoded_field = false
        size = 0
        invalid = false

        until reader.done?
          if reader.current_byte.bit(7) == 1           # 1.......  indexed
            index = integer(7)
            raise Error.new("invalid index: 0") if index == 0
            name, value = indexed(index)

          elsif reader.current_byte.bit(6) == 1        # 01......  literal with incremental indexing
            index = integer(6)
            name = index == 0 ? string : indexed(index).first
            value = string
            table.add(name, value)

          elsif reader.current_byte.bit(5) == 1        # 001.....  table max size update
            raise Error.new("unexpected dynamic table size update") if decoded_field
            if (new_size = integer(5)) > max_table_size
              raise Error.new("dynamic table size update is larger than SETTINGS_HEADER_TABLE_SIZE")
            end
            table.resize(new_size)
            next

          elsif reader.current_byte.bit(4) == 1        # 0001....  literal never indexed
            index = integer(4)
            name = index == 0 ? string : indexed(index).first
            value = string
            # TODO: retain the never_indexed property

          else                                         # 0000....  literal without indexing
            index = integer(4)
            name = index == 0 ? string : indexed(index).first
            value = string
          end

          decoded_field = true
          size += name.bytesize + value.bytesize + 32
          if max_size && size > max_size
            raise ListSizeError.new("header list size exceeds #{max_size}")
          end
          if valid_name?(name) && headers.valid_value?(value)
            headers.add(name, value)
          else
            invalid = true
          end
        end

        raise InvalidFieldError.new("invalid header field") if invalid
        headers
      rescue ex : IndexError
        raise Error.new("invalid compression")
      end

      # A token, or a pseudo-header field name `HTTP::Headers` accepts.
      private def valid_name?(name : String) : Bool
        name.starts_with?(':') ? name.in?(HTTP::Headers::PSEUDO_HEADER_NAMES) : HTTP::Headers.token?(name)
      end

      protected def indexed(index)
        if 0 < index <= STATIC_TABLE_SIZE
          return STATIC_TABLE[index - 1]
        end

        if index > STATIC_TABLE_SIZE && (header = table[index - STATIC_TABLE_SIZE - 1]?)
          return header
        end

        raise Error.new("invalid index: #{index}")
      end

      protected def integer(n)
        integer = (reader.read_byte & (0xff >> (8 - n))).to_i
        n2 = 2 ** n - 1
        return integer if integer < n2

        value = integer.to_i64
        m = 0
        loop do
          byte = reader.read_byte
          value += (byte & 127).to_i64 << (m * 7)
          raise Error.new("integer exceeds #{MAX_INTEGER}") if value > MAX_INTEGER
          break unless byte & 128 == 128
          m += 1
          # more continuation bytes than MAX_INTEGER needs
          raise Error.new("integer exceeds #{MAX_INTEGER}") if m * 7 > 31
        end

        value.to_i32
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

    class Encoder
      # TODO: allow per header name/value indexing configuration
      # TODO: allow per header name/value huffman encoding configuration

      private getter! writer : IO::Memory
      getter table : DynamicTable
      property default_indexing : Indexing
      property default_huffman : Bool

      def initialize(indexing = Indexing::NONE, huffman = false, max_table_size = 4096)
        @default_indexing = indexing
        @default_huffman = huffman
        @table = DynamicTable.new(max_table_size)
      end

      def encode(headers : HTTP::Headers, indexing = default_indexing, huffman = default_huffman, @writer = IO::Memory.new)
        headers.each { |name, values| encode(name.downcase, values, indexing, huffman) if name.starts_with?(':') }
        headers.each { |name, values| encode(name.downcase, values, indexing, huffman) unless name.starts_with?(':') }
        writer.to_slice
      end

      def encode(name, values, indexing, huffman)
        values.each do |value|
          if header = indexed(name, value)
            if header[1]
              integer(header[0], 7, prefix: Indexing::INDEXED)
            elsif indexing == Indexing::ALWAYS
              integer(header[0], 6, prefix: Indexing::ALWAYS)
              string(value, huffman)
              table.add(name, value)
            else
              integer(header[0], 4, prefix: Indexing::NONE)
              string(value, huffman)
            end
          else
            case indexing
            when Indexing::ALWAYS
              table.add(name, value)
              writer.write_byte(Indexing::ALWAYS.value)
            when Indexing::NEVER
              writer.write_byte(Indexing::NEVER.value)
            else
              writer.write_byte(Indexing::NONE.value)
            end
            string(name, huffman)
            string(value, huffman)
          end
        end
      end

      protected def indexed(name, value)
        # OPTIMIZE: use a cached { name => { value => index } } struct (?)
        idx = nil

        STATIC_TABLE.each_with_index do |header, index|
          if header[0] == name
            if header[1] == value
              return {index + 1, value}
            else
              idx ||= index + 1
            end
          end
        end

        table.each_with_index do |header, index|
          if header[0] == name
            if header[1] == value
              return {index + STATIC_TABLE_SIZE + 1, value}
            #else
            #  idx ||= index + 1
            end
          end
        end

        if idx
          {idx, nil}
        end
      end

      protected def integer(integer : Int32, n, prefix = 0_u8)
        n2 = 2 ** n - 1

        if integer < n2
          writer.write_byte(integer.to_u8 | prefix.to_u8)
          return
        end

        writer.write_byte(n2.to_u8 | prefix.to_u8)
        integer -= n2

        while integer >= 128
          writer.write_byte(((integer % 128) + 128).to_u8)
          integer /= 128
        end

        writer.write_byte(integer.to_u8)
      end

      protected def string(string : String, huffman = false)
        if huffman
          encoded = HPACK.huffman.encode(string)
          integer(encoded.size, 7, prefix: 128)
          writer.write(encoded)
        else
          integer(string.bytesize, 7)
          writer << string
        end
      end
    end
  end
end
