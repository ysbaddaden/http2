require "sync/mu"
require "sync/cv"

# A Circular Buffer IO object.
#
# Allocates a memory buffer of a fixed capacity that will never be reallocated.
# Two position pointers to the buffer are maintained: the current write and read
# positions. These positions will overflow back to the beginning when the buffer
# capacity is reached, creating the illusion of a circular buffer structure.
#
# Example:
# ```
# io = HTTP2::CircularBuffer.new(32)
#
# io.write(UInt8.slice(1, 2, 3, 4, 5))
# p io.size # => 5
#
# io.close(:write)
# p io.closed?(:write) # => true
# p io.closed?(:read)  # => false
#
# bytes = Bytes.new(32)
# io.read(bytes) # => 5
# p io.size      # => 0
# p bytes        # => Slice[1, 2, 3, 4, 5]
#
# io.read(bytes) # => 0
# ```
#
# The circular buffer memory IO is `Fiber` aware. The `#read` and `#write` calls
# will block the current fiber when nothing can be read (empty buffer) or when
# nothing can be written (full buffer).
#
# The following example will write 16 bytes then block until at least 8 bytes
# are read from it:
# ```
# io = HTTP2::CircularBuffer.new(16)
# io.write(Bytes.new(24))
# ```
#
# This will block until at least 1 byte is written:
# ```
# io = HTTP2::CircularBuffer.new(16)
# io.read(Bytes.new(8))
# ```
class HTTP2::CircularBuffer < IO
  @[Flags]
  enum Closed
    Read
    Write
  end

  getter bytesize : Int32
  getter capacity : Int32

  def initialize(capacity : Int)
    String.check_capacity_in_bounds(capacity)
    @capacity = capacity.to_i
    @buffer = Pointer(UInt8).null
    @read_offset = 0
    @write_offset = 0
    @bytesize = 0
    @closed = Closed::None
    @mu = Sync::MU.new
    @readers = Sync::CV.new
    @writers = Sync::CV.new
  end

  # Returns the current size of the buffer, that is how many bytes are available
  # for read.
  def size
    @bytesize
  end

  def empty?
    @bytesize == 0
  end

  def any?
    @bytesize != 0
  end

  def full?
    @bytesize == @capacity
  end

  # Close the buffer for reading or writing or both.
  def close(closed : Closed = :all) : Nil
    synchronize do
      @closed |= closed
      @readers.broadcast if closed.read?
      @writers.broadcast if closed.write?
    end
  end

  def closed?(closed : Closed = :all)
    (@closed & closed) == closed
  end

  # Tries to fill the slice with bytes from the buffer. If the buffer is empty,
  # and the buffer isn't write closed, then the current fiber will block until
  # some bytes are written to the buffer.
  def read(slice : Bytes)
    read_impl(slice.size) do |len|
      (buffer + @read_offset).copy_to(slice.to_unsafe, len)
      slice += len
    end
  end

  # Writes up to `size` bytes from the buffer directly to the IO, avoiding an
  # intermediary Slice. This will block if the buffer is empty.
  def copy_to(io : IO, size : Int)
    read_impl(size.to_i) do |len|
      slice = (buffer + @read_offset).to_slice(len)
      io.write(slice)
    end
  end

  # Copies all bytes from the slice to the buffer. If the resulting buffer would
  # end up over capacity, the buffer will be filled, then the current fiber will
  # block until some bytes are read from the buffer.
  def write(slice : Bytes) : Nil
    write_impl(slice.size) do |len|
      (buffer + @write_offset).copy_from(slice.to_unsafe, len)
      slice += len
    end
  end

  # Reads `size` bytes from the IO and writes them directly to the buffer,
  # avoiding an intermediary Slice. This will block if the buffer is full.
  def copy_from(io : IO, size : Int)
    write_impl(size.to_i) do |len|
      slice = (buffer + @write_offset).to_slice(len)
      io.read_fully(slice)
    end
  end

  private def synchronize(&)
    @mu.lock
    begin
      yield
    ensure
      @mu.unlock
    end
  end

  private def read_impl(total, &)
    count = 0

    synchronize do
      while true
        available = wait_readable
        break if available == 0 # EOF

        len = Math.min(total - count, available)
        yield len

        @read_offset = (@read_offset + len) % @capacity
        @bytesize -= len
        count += len

        @writers.signal
        break if count == total || empty?
      end
    end

    count
  end

  private def write_impl(total, &)
    count = total

    synchronize do
      while true
        available = wait_writeable

        len = Math.min(count, available)
        yield len

        @write_offset = (@write_offset + len) % @capacity
        @bytesize += len
        count -= len

        @readers.signal
        return total if count == 0
      end
    end
  end

  private def readable_bytesize
    if @read_offset < @write_offset
      @write_offset - @read_offset
    elsif @read_offset > @write_offset || any?
      @capacity - @read_offset
    else
      0
    end
  end

  private def writeable_bytesize
    if @read_offset > @write_offset
      @capacity - @bytesize
    elsif @read_offset < @write_offset || empty?
      @capacity - @write_offset
    else
      0
    end
  end

  # NOTE: @mu must be locked
  private def wait_readable
    while true
      if @closed.read?
        raise IO::Error.new("Closed stream")
      end

      available = readable_bytesize
      return available unless available == 0
      return 0 if @closed.write? # EOF

      @readers.wait pointerof(@mu)
    end
  end

  # NOTE: @mu must be locked
  private def wait_writeable
    while true
      unless @closed.none?
        raise IO::Error.new("Closed stream")
      end

      available = writeable_bytesize
      return available unless available == 0

      @writers.wait pointerof(@mu)
    end
  end

  private def buffer
    @buffer ||= GC.malloc_atomic(@capacity).as(UInt8*)
  end
end
