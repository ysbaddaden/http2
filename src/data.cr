module HTTP2
  class Data
    include IO

    getter size : Int32
    @r : IO #::FileDescriptor
    @w : IO #::FileDescriptor

    def initialize
      # OPTIMIZE: replace pipe with in-memory struct (or tempfile if it grows too big)
      @r, @w = IO.pipe(read_blocking: false, write_blocking: false)
      @size = 0
    end

    def read(slice : Slice(UInt8))
      @r.read(slice)
    end

    def write(slice : Slice(UInt8))
      @size += slice.size
      @w.write(slice)
    end

    def close_read
      @r.close unless @r.closed?
    end

    def close_write
      @w.close unless @w.closed?
    end

    def close
      close_read
      close_write
    end
  end
end
