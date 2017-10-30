require "./io/circular_buffer"

module HTTP2
  # Wraps a circular buffer to buffer incoming DATA. The buffer capacity is the
  # initial window size. The stream window size decreases whenever reading and a
  # WINDOW_UPDATE frame will be sent whenever the window size falls below half
  # the buffer size (incremented by half the buffer size).
  class Data
    include IO

    # :nodoc:
    alias Closed = IO::CircularBuffer::Closed

    @stream : Stream
    @buffer : IO::CircularBuffer?
    @inbound_window_size : Int32
    @size : Int32

    # :nodoc:
    protected def initialize(@stream, window_size)
      @inbound_window_size = window_size
      @size = 0
    end

    # Initializes buffer on demand.
    private def buffer
      # NOTE: thread safety (?)
      @buffer ||= IO::CircularBuffer.new(@inbound_window_size)
    end

    # Reads previously buffered DATA.
    #
    # If window size falls below half buffer capacity, sends a WINDOW_UPDATE
    # frame to increment the window size by half the buffer size, which fits
    # into the buffer's remaining space.
    def read(slice : Bytes) : Int32
      bytes_read = buffer.read(slice)
      @inbound_window_size -= bytes_read

      unless bytes_read == 0
        increment = buffer.capacity # / 2

        #if @inbound_window_size <= increment
        if @inbound_window_size <= 0
          @inbound_window_size += increment
          @stream.send_window_update_frame(increment)
        end
      end

      bytes_read
    end

    # :nodoc:
    def write(slice : Bytes)
      # Buffers *incoming* DATA from HTTP/2 connection.
      @size += slice.size
      buffer.write(slice)
    end

    protected def copy_from(io : IO, size : Int32)
      @size += size
      if (buffer.capacity - buffer.size) < size
        raise ArgumentError.new
      end
      buffer.copy_from(io, size)
    end

    def close_read : Nil
      buffer.close(Closed::Read) unless buffer.closed?(Closed::Read)
    end

    protected def close_write : Nil
      buffer.close(Closed::Write) unless buffer.closed?(Closed::Write)
    end

    def close : Nil
      close_read
      close_write
    end

    # Returns the collected size in bytes of streamed DATA frames.
    def size
      @size
    end
  end
end
