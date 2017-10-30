require "./config"
require "./errors"

module HTTP2
  class Settings
    # See https://tools.ietf.org/html/rfc7540#section-11.3
    enum Identifier : UInt16
      HEADER_TABLE_SIZE = 0x1
      ENABLE_PUSH = 0x2
      MAX_CONCURRENT_STREAMS = 0x3
      INITIAL_WINDOW_SIZE = 0x4
      MAX_FRAME_SIZE = 0x5
      MAX_HEADER_LIST_SIZE = 0x6
    end

    setter header_table_size : Int32
    setter enable_push : Bool
    setter max_concurrent_streams : Int32
    getter max_concurrent_streams : Int32?
    setter initial_window_size : Int32
    setter max_header_list_size : Int32
    getter max_header_list_size : Int32?

    @header_table_size : Int32?
    @enable_push : Bool?
    @max_concurrent_streams : Int32?
    @initial_window_size : Int32?
    @max_frame_size : Int32?
    @max_header_list_size : Int32?

    # :nodoc:
    protected def initialize(
      @header_table_size = nil,
      @enable_push = nil,
      @max_concurrent_streams = nil,
      @initial_window_size = nil,
      @max_frame_size = nil,
      @max_header_list_size = nil
    )
    end

    def header_table_size : Int32
      @header_table_size || DEFAULT_HEADER_TABLE_SIZE
    end

    def enable_push : Bool
      @enable_push || DEFAULT_ENABLE_PUSH
    end

    def initial_window_size : Int32
      @initial_window_size || DEFAULT_INITIAL_WINDOW_SIZE
    end

    def initial_window_size=(size : Int32)
      raise Error.flow_control_error unless 0 <= size < MAXIMUM_WINDOW_SIZE
      @initial_window_size = size
    end

    def max_frame_size : Int32
      @max_frame_size || DEFAULT_MAX_FRAME_SIZE
    end

    def max_frame_size=(size : Int32)
      unless MINIMUM_FRAME_SIZE <= size < MAXIMUM_FRAME_SIZE
        raise Error.protocol_error("INVALID frame size: #{size}")
      end
      @max_frame_size = size
    end

    def parse(bytes : Bytes) : Nil
      parse(IO::Memory.new(bytes), bytes.size / 6) do |id, value|
        yield id, value
      end
    end

    def parse(io : IO, size : Int32) : Nil
      size.times do |i|
        id = Identifier.from_value?(io.read_bytes(UInt16, IO::ByteFormat::BigEndian))
        value = io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i32
        next unless id # unknown setting identifier

        yield id, value

        case id
        when Identifier::HEADER_TABLE_SIZE
          self.header_table_size = value
        when Identifier::ENABLE_PUSH
          raise Error.protocol_error unless value == 0 || value == 1
          self.enable_push = value == 1
        when Identifier::MAX_CONCURRENT_STREAMS
          self.max_concurrent_streams = value
        when Identifier::INITIAL_WINDOW_SIZE
          self.initial_window_size = value
        when Identifier::MAX_FRAME_SIZE
          self.max_frame_size = value
        when Identifier::MAX_HEADER_LIST_SIZE
          self.max_header_list_size = value
        end
      end
    end

    def to_payload : Bytes
      io = IO::Memory.new(size * 6)

      {% for name in Identifier.constants %}
        if value = @{{ name.underscore }}
          io.write_bytes(Identifier::{{ name }}.to_u16, IO::ByteFormat::BigEndian)
          if value.is_a?(Bool)
            io.write_bytes(value ? 1_u32 : 0_u32, IO::ByteFormat::BigEndian)
          else
            io.write_bytes(value.to_u32, IO::ByteFormat::BigEndian)
          end
        end
      {% end %}

      io.to_slice
    end

    # :nodoc:
    def size : Int32
      num = 0
      {% for name in Identifier.constants %}
        num += 1 if @{{ name.underscore }}
      {% end %}
      num
    end
  end
end
