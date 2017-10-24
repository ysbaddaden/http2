require "./io/circular_buffer"

module HTTP2
  # Wraps a circular buffer to buffer incoming DATA. The buffer is initialized
  # to the window size. The window size decreases whenever reading and a
  # WINDOW_UPDATE frame will be sent whenever the window size falls below half
  # the buffer size (incremented by half the buffer size).
  class Data
    include IO

    alias Closed = IO::CircularBuffer::Closed

    @stream : Stream
    @buffer : IO::CircularBuffer
    @window_size : Int32
    @size : Int32

    def initialize(@stream, window_size)
      @window_size = window_size
      @size = 0
      @buffer = IO::CircularBuffer.new(window_size)
    end

    # Reads previously buffered DATA.
    #
    # If window size falls below half buffer capacity, sends a WINDOW_UPDATE
    # frame to increment the window size by half the buffer size, which fits
    # into the buffer's remaining space.
    def read(slice : Slice(UInt8)) : Int32
      bytes_read = @buffer.read(slice)
      @window_size -= bytes_read

      unless bytes_read == 0
        increment = @buffer.capacity / 2

        if @window_size <= increment
          @window_size += increment
          @stream.send_window_update_frame(increment)
        end
      end

      bytes_read
    end

    # Buffers *incoming* DATA from HTTP/2 connection.
    def write(slice : Slice(UInt8))
      @size += slice.size
      @buffer.write(slice)
    end

    def close_read
      @buffer.close(Closed::Read) unless @buffer.closed?(Closed::Read)
    end

    def close_write
      @buffer.close(Closed::Write) unless @buffer.closed?(Closed::Write)
    end

    def close
      close_read
      close_write
    end

    # Returns the collected size in bytes of streamed DATA frames.
    def size
      @size
    end
  end
end
