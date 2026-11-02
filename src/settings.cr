require "./config"
require "./errors"

module HTTP2
  class Settings
    # See https://tools.ietf.org/html/rfc7540#section-11.3
    enum Identifier : UInt16
      HEADER_TABLE_SIZE      = 0x1
      ENABLE_PUSH            = 0x2
      MAX_CONCURRENT_STREAMS = 0x3
      INITIAL_WINDOW_SIZE    = 0x4
      MAX_FRAME_SIZE         = 0x5
      MAX_HEADER_LIST_SIZE   = 0x6
    end

    # Each value is read and written at once, so a fiber may read the
    # settings while the fiber that receives frames changes them: -1 for a
    # value that isn't set.
    @header_table_size = Atomic(Int64).new(-1)
    @enable_push = Atomic(Int64).new(-1)
    @max_concurrent_streams = Atomic(Int64).new(-1)
    @initial_window_size = Atomic(Int64).new(-1)
    @max_frame_size = Atomic(Int64).new(-1)
    @max_header_list_size = Atomic(Int64).new(-1)

    # :nodoc:
    protected def initialize(
      header_table_size : UInt32? = nil,
      enable_push : Bool? = nil,
      max_concurrent_streams : UInt32? = nil,
      initial_window_size : UInt32? = nil,
      max_frame_size : UInt32? = nil,
      max_header_list_size : UInt32? = nil,
    )
      @header_table_size.set(header_table_size.to_i64) if header_table_size
      @enable_push.set(enable_push ? 1_i64 : 0_i64) unless enable_push.nil?
      @max_concurrent_streams.set(max_concurrent_streams.to_i64) if max_concurrent_streams
      @initial_window_size.set(initial_window_size.to_i64) if initial_window_size
      @max_frame_size.set(max_frame_size.to_i64) if max_frame_size
      @max_header_list_size.set(max_header_list_size.to_i64) if max_header_list_size
    end

    # :nodoc:
    def dup : self
      Settings.new(
        header_table_size: value(@header_table_size).try(&.to_u32),
        enable_push: value(@enable_push).try(&.==(1)),
        max_concurrent_streams: value(@max_concurrent_streams).try(&.to_u32),
        initial_window_size: value(@initial_window_size).try(&.to_u32),
        max_frame_size: value(@max_frame_size).try(&.to_u32),
        max_header_list_size: value(@max_header_list_size).try(&.to_u32),
      )
    end

    private def value(atomic : Atomic(Int64)) : Int64?
      value = atomic.get
      value unless value < 0
    end

    def header_table_size : Int32
      (value(@header_table_size) || DEFAULT_HEADER_TABLE_SIZE).to_i32
    end

    def header_table_size=(value : Int)
      @header_table_size.set(value.to_u32.to_i64)
    end

    def enable_push : Bool
      if value = value(@enable_push)
        value == 1
      else
        DEFAULT_ENABLE_PUSH
      end
    end

    def enable_push=(value : Bool)
      @enable_push.set(value ? 1_i64 : 0_i64)
    end

    def max_concurrent_streams : UInt32?
      value(@max_concurrent_streams).try(&.to_u32)
    end

    def max_concurrent_streams=(value : Int)
      @max_concurrent_streams.set(value.to_u32.to_i64)
    end

    def initial_window_size : Int32
      (value(@initial_window_size) || DEFAULT_INITIAL_WINDOW_SIZE).to_i32
    end

    def initial_window_size=(size : Int)
      raise Error.flow_control_error unless 0 <= size <= MAXIMUM_WINDOW_SIZE
      @initial_window_size.set(size.to_i64)
    end

    def max_frame_size : Int32
      (value(@max_frame_size) || DEFAULT_MAX_FRAME_SIZE).to_i32
    end

    def max_frame_size=(size : Int)
      unless MINIMUM_FRAME_SIZE <= size <= MAXIMUM_FRAME_SIZE
        raise Error.protocol_error("INVALID frame size: #{size}")
      end
      @max_frame_size.set(size.to_i64)
    end

    def max_header_list_size : Int32?
      value(@max_header_list_size).try(&.to_i32)
    end

    def max_header_list_size=(value : Int)
      @max_header_list_size.set(value.to_u32.to_i64)
    end

    def parse(bytes : Bytes, &) : Nil
      parse(IO::Memory.new(bytes), bytes.size // 6) do |id, value|
        yield id, value
      end
    end

    def parse(io : IO, size : Int32, &) : Nil
      size.times do |i|
        id = Identifier.from_value?(io.read_bytes(UInt16, IO::ByteFormat::BigEndian))
        value = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
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
        if value = value(@{{ name.underscore }})
          io.write_bytes(Identifier::{{ name }}.to_u16, IO::ByteFormat::BigEndian)
          io.write_bytes(value.to_u32, IO::ByteFormat::BigEndian)
        end
      {% end %}

      io.to_slice
    end

    # :nodoc:
    def size : Int32
      num = 0
      {% for name in Identifier.constants %}
        num += 1 if value(@{{ name.underscore }})
      {% end %}
      num
    end
  end
end
