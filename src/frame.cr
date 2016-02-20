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
        end_headers?
      end

      def inspect(io)
        to_s(io)
      end

      def to_s(io)
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
    property stream_id : Int32
    property flags : Flags
    property! payload : Slice(UInt8)

    def initialize(@type, @stream_id = 0, flags = 0_u8, @payload = nil)
      @flags = Flags.new(flags.to_u8)
    end

    def inspect(io : IO)
      io << "#{type} frame <stream_id=#{stream_id} flags=#{flags}>"
    end
  end
end
