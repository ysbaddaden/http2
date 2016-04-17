module HTTP2
  class Data
    include IO

    @r : IO #::FileDescriptor
    @w : IO #::FileDescriptor

    def initialize
      # OPTIMIZE: replace pipe with in-memory struct (or tempfile if it grows too big)
      @r, @w = IO.pipe(read_blocking: false, write_blocking: false)
    end

    def read(slice : Slice(UInt8))
      @r.read(slice)
    end

    def write(slice : Slice(UInt8))
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
