module HTTP2
  class Frame
    # See https://tools.ietf.org/html/rfc7540#section-11.2
    enum Type
      DATA = 0x0
      HEADERS = 0x1
      PRIORITY = 0x2
      RST_STREAM = 0x3
      SETTINGS = 0x4
      PUSH_PROMISE = 0x5
      PING = 0x6
      GOAWAY = 0x7
      WINDOW_UPDATE = 0x8
      CONTINUATION = 0x9
    end

    @[Flags]
    enum Flags : UInt8
      END_STREAM = 0x1_u8
      END_HEADERS = 0x4_u8
      PADDED = 0x8_u8
      PRIORITY = 0x20_u8

      def ack?
        end_stream?
      end

      def inspect(io)
        to_s(io)
      end

      def to_s(io)
        if value == 0
          io << "NONE"
          return
        end

        i = 0
        {% for name in @type.constants %}
          {% unless name.stringify == "None" || name.stringify == "All" %}
            if {{ name.downcase }}?
              io << "|" unless i == 0
              io << {{ name.stringify }}
              i += 1
            end
          {% end %}
        {% end %}
      end
    end

    property type : Type
    getter stream : Stream
    property flags : Flags
    property! payload : Slice(UInt8)
    @size : Int32?

    def initialize(@type, @stream : Stream, flags = 0_u8, @payload = nil, size = nil)
      @flags = Flags.new(flags.to_u8)
      @size = size.try(&.to_i32)
    end

    def size
      @size || payload?.try(&.size) || 0
    end

    def debug(color = nil)
      flags = (type == Type::SETTINGS || type == Type::PING) && @flags.value == 1 ? "ACK" : @flags
      type = if color; @type.colorize(color); else; @type; end
      "#{type} frame <length=#{size}, flags=#{flags}, stream_id=#{stream.id}>"
    end
  end
end
