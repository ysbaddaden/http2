module HTTP2
  class SliceReader
    getter offset : Int32
    getter bytes : Bytes
    getter default_endianness : IO::ByteFormat

    def initialize(@bytes : Bytes, @default_endianness = IO::ByteFormat::SystemEndian)
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

    {% for type, i in %w(UInt8 Int8 UInt16 Int16 UInt32 Int32 UInt64 Int64) %}
      def read_bytes(type : {{ type.id }}.class, endianness = default_endianness)
        {% size = 2 ** (i // 2) %}

        buffer = bytes[offset, {{ size }}]
        @offset += {{ size }}

        {% if size > 1 %}
          unless endianness == IO::ByteFormat::SystemEndian
            buffer.reverse!
          end
        {% end %}

        buffer.to_unsafe.as(Pointer({{ type.id }})).value
      end
    {% end %}

    def read(count)
      count = bytes.size - offset - count if count < 0
      bytes[offset, count].tap { @offset += count }
    end
  end
end
