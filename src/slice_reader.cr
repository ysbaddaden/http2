module HTTP2
  class SliceReader
    getter offset : Int32
    getter bytes : Slice(UInt8)
    getter default_endianness : IO::ByteFormat

    def initialize(@bytes : Slice(UInt8), @default_endianness = IO::ByteFormat::SystemEndian)
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

    {% for type, i in %w(UInt16 UInt32 UInt64) %}
      def read_bytes(type : {{ type.id }}.class, endianness = default_endianness)
        {% size = 2 ** (i + 1) %}
        buffer = bytes[offset, {{ size }}]
        @offset += {{ size }}

        unless endianness == IO::ByteFormat::SystemEndian
          buffer = Slice(UInt8).new({{ size }}) { |i| buffer[{{ size - 1 }} - i] }
        end

        (buffer.to_unsafe as Pointer({{ type.id }})).value
      end
    {% end %}

    def read(count)
      bytes[offset, count].tap { @offset += count }
    end
  end
end
