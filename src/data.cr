require "./circular_buffer"

module HTTP2
  # Wraps a circular buffer to buffer incoming DATA. The buffer capacity is the
  # initial window size. The stream window size decreases whenever reading and a
  # WINDOW_UPDATE frame will be sent whenever the window size falls to half the
  # buffer size or the buffer was emptied (incremented by the size that was
  # read).
  class Data < IO
    # :nodoc:
    alias Closed = CircularBuffer::Closed

    @stream : Stream
    @buffer = uninitialized ReferenceStorage(CircularBuffer)
    @inbound_window_size : Int32
    @size : Int32

    # :nodoc:
    protected def initialize(@stream, window_size)
      @inbound_window_size = window_size
      @size = 0
      @buffer = uninitialized ReferenceStorage(CircularBuffer)
      CircularBuffer.unsafe_construct(pointerof(@buffer), @inbound_window_size)
    end

    private def buffer
      @buffer.to_reference
    end

    # Reads previously buffered DATA.
    #
    # Once half the buffer capacity was read, or the buffer is empty (the peer
    # may be waiting for the window), sends a WINDOW_UPDATE frame to increment
    # the window size by the size that was read, which fits into the buffer's
    # free space, unless the whole body was received.
    def read(slice : Bytes) : Int32
      bytes_read = buffer.read(slice)
      @inbound_window_size -= bytes_read

      if bytes_read > 0 && (@inbound_window_size <= buffer.capacity // 2 || buffer.empty?) && !complete?
        increment = buffer.capacity - @inbound_window_size
        @inbound_window_size += increment
        @stream.send_window_update_frame(increment)
      end

      bytes_read
    end

    # :nodoc:
    def write(slice : Bytes) : Nil
      # Buffers *incoming* DATA from HTTP/2 connection.
      @size += slice.size
      buffer.write(slice)
    end

    # Buffers *size* bytes of DATA from *io*. Returns false if the body was
    # closed, for example by another fiber that reset the stream while the
    # DATA was being received: the rest of the bytes is skipped then.
    #
    # Reads the bytes into *scratch* first, then copies them into the
    # buffer: the buffer isn't locked while the peer sends them, so a fiber
    # that closes the body doesn't wait for a peer that stalls in the
    # middle of a frame.
    protected def copy_from(io : IO, size : Int32, scratch : Bytes) : Bool
      @size += size
      if (buffer.capacity - buffer.size) < size
        raise ArgumentError.new
      end
      while size > 0
        chunk = scratch[0, Math.min(size, scratch.size)]
        io.read_fully(chunk)
        size -= chunk.size
        begin
          # the flow-control window leaves room for the bytes: a closed
          # buffer raises before any byte is copied
          buffer.write(chunk)
        rescue ex : IO::Error
          raise ex unless buffer.closed?(:read) || buffer.closed?(:write)
          io.skip(size)
          return false
        end
      end
      true
    end

    # Returns true once the whole body was received (END_STREAM).
    protected def complete? : Bool
      buffer.closed?(:write)
    end

    def close_read : Nil
      buffer.close(:read) unless buffer.closed?(:read)
    end

    protected def close_write : Nil
      buffer.close(:write) unless buffer.closed?(:write)
    end

    def close : Nil
      buffer.close unless buffer.closed?
    end

    # Returns the collected size in bytes of streamed DATA frames.
    def size
      @size
    end
  end
end
