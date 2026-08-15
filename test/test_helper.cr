require "minitest/autorun"

module AsyncTest
  @exception : Exception?

  def before_setup
    super
    @done = @exception = nil
  end

  def after_teardown
    @done = @exception = nil
    super
  end

  def wait
    loop do
      Fiber.yield
      break if @done
    end

    if exception = @exception
      raise exception
    end
  end

  def async(&block)
    @done = false

    spawn do
      begin
        block.call
      rescue ex
        @exception = ex
      ensure
        @done = true
      end
    end
  end
end

module HTTP2
  module TestHelpers
    def new_connection(type : Connection::Type, *frames)
      io = IO::Memory.new
      frames.each { |frame| write_frame(io, *frame) }
      io.rewind
      Connection.new(io, type)
    end

    def write_frame(io : IO, type : Frame::Type, flags : Frame::Flags, stream_id : Int, payload : Bytes? = nil)
      size = payload.try(&.size.to_u32) || 0_u32
      io.write_bytes((size << 8) | type.to_u8, IO::ByteFormat::BigEndian)
      io.write_byte(flags.to_u8)
      io.write_bytes(stream_id.to_u32, IO::ByteFormat::BigEndian)
      io.write(payload) if payload
    end
  end
end

class Minitest::Test
  include AsyncTest
  include HTTP2::TestHelpers
end
