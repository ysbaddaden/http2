class IO::Hexdump
  include IO

  def initialize(@io : IO, @logger : Logger|Logger::Dummy, @read = true, @write = true)
  end

  def read(buf : Slice(UInt8))
    @io.read(buf).tap do
      @logger.debug(hexdump(buf)) if @read
    end
  end

  def write(buf : Slice(UInt8))
    @io.write(buf).tap do
      @logger.debug(hexdump(buf)) if @write
    end
  end

  def closed?
    @io.closed?
  end

  def close
    @io.close
  end

  def flush
    @io.flush
  end

  private def hexdump(buf)
    offset = 0
    line = MemoryIO.new(48)

    String.build do |str|
      buf.each_with_index do |byte, index|
        if index > 0
          if index % 16 == 0
            str.print line.to_s
            hexdump(buf, offset - 15, str)
            str.print '\n'
            line = MemoryIO.new(48)
          elsif index % 8 == 0
            line.print "  "
          else
            line.print ' '
          end
        end

        s = byte.to_s(16)
        line.print '0' if s.size == 1
        line.print s

        offset = index
      end

      if line.pos > 0
        str.print line.to_s
        (48 - line.pos).times { str.print ' ' }
        hexdump(buf, offset - (offset % 16), str)
      end
    end
  end

  private def hexdump(buf, offset, str)
    len = Math.min(16, buf.size - offset)

    str.print "  |"

    buf[offset, len].each do |byte|
      if 31 < byte < 127
        str.print byte.chr
      else
        str.print '.'
      end
    end

    (len ... 16).each { str.print ' ' }

    str.print '|'
  end
end
