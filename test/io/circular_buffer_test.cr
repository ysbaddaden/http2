require "../test_helper"
require "../../src/io/circular_buffer"

class IO::CircularBufferTest < Minitest::Test
  def test_close
    cb = IO::CircularBuffer.new(32)
    cb.close
    assert cb.closed?
    assert cb.closed?(IO::CircularBuffer::Closed::Read)
    assert cb.closed?(IO::CircularBuffer::Closed::Write)
  end

  def test_close_read
    cb = IO::CircularBuffer.new(32)
    cb.close(IO::CircularBuffer::Closed::Read)
    refute cb.closed?
    assert cb.closed?(IO::CircularBuffer::Closed::Read)
    refute cb.closed?(IO::CircularBuffer::Closed::Write)
  end

  def test_close_write
    cb = IO::CircularBuffer.new(32)
    cb.close(IO::CircularBuffer::Closed::Write)
    refute cb.closed?
    refute cb.closed?(IO::CircularBuffer::Closed::Read)
    assert cb.closed?(IO::CircularBuffer::Closed::Write)
  end

  def test_close_resumes_pending_read_fiber
    cb = IO::CircularBuffer.new(32)
    async { cb.write Bytes.new(64) }
    cb.close
    assert_raises(IO::Error) { wait }
  end

  def test_close_resumes_pending_write_fiber
    cb = IO::CircularBuffer.new(32)
    async { cb.read Bytes.new(64) }
    cb.close
    assert_raises(IO::Error) { wait }
  end

  def test_read_from_closed_stream
    cb = IO::CircularBuffer.new(32)
    cb.close(IO::CircularBuffer::Closed::Read)
    assert_raises(IO::Error) { cb.read(Bytes.new(1)) }
  end

  def test_write_to_closed_stream
    cb = IO::CircularBuffer.new(32)
    cb.close(IO::CircularBuffer::Closed::Write)
    assert_raises(IO::Error) { cb.write(Bytes.new(1)) }
  end

  def test_eof
    buf = Bytes.new(1) { 1_u8 }
    buf2 = Bytes.new(2)

    cb = IO::CircularBuffer.new(32)
    cb.write(buf)
    cb.close(IO::CircularBuffer::Closed::Write)

    assert_equal 1, cb.read(buf2)
    assert_equal 1, buf2[0]
    assert_equal 0, cb.read(buf2)
  end

  def test_read_and_write_within_capacity
    buf = Bytes.new(16) { |i| i.to_u8 * 2 }
    buf2 = Bytes.new(16)
    cb = IO::CircularBuffer.new(32)

    cb.write(buf)
    assert_equal 16, cb.size

    cb.write(buf)
    assert_equal 32, cb.size

    assert_equal 16, cb.read(buf2)
    assert_equal 16, cb.size
    assert_equal buf, buf2

    assert_equal 16, cb.read(buf2)
    assert_equal 0, cb.size
    assert_equal buf, buf2
  end

  def test_circular_read_and_write_within_capacity
    buf2 = Bytes.new(16)
    cb = IO::CircularBuffer.new(32)

    1.upto(10) do |i|
      buf = Bytes.new(16) { |j| j.to_u8 * i }
      cb.write(buf)
      assert_equal 16, cb.read(buf2)
      assert_equal buf2, buf
    end
  end

  def test_write_over_capacity
    buf1 = Bytes.new(32) { |i| i.to_u8 }
    buf2 = Bytes.new(32) { |i| i.to_u8 * 2 }
    buf3 = Bytes.new(32)

    cb = IO::CircularBuffer.new(32)
    cb.write(buf1)

    spawn do
      cb.write(buf2)
    end

    cb.read(buf3)
    assert_equal buf1, buf3

    cb.read(buf3)
    assert_equal buf2, buf3
  end

  def test_read_and_write_overflow_to_full_capacity
    cb = IO::CircularBuffer.new(32)
    cb.write(Bytes.new(8))
    cb.skip(8)

    buf = Bytes.new(32) { |j| j.to_u8 + 1 }
    cb.write(buf)

    cb.read(buf2 = Bytes.new(32))
    assert_equal buf, buf2
  end

  def test_read_and_write_overflow
    buf = Bytes.new(24) { |j| j.to_u8 * 2 }
    buf2 = Bytes.new(16)

    cb = IO::CircularBuffer.new(32)
    cb.write(buf)
    cb.skip(8)

    cb.write(buf[0, 16])
    cb.skip(16)

    cb.read(buf2)
    assert_equal buf[0, 16], buf2
  end

  def test_read_and_write_over_capacity_slices
    i = Bytes.new(1 * 1024 * 1024) { |i| i.to_u8! }
    o = Bytes.new(1 * 1024 * 1024)
    cb = IO::CircularBuffer.new(64 * 1024)

    fiber = Fiber.current
    read = 0

    spawn do
      cb.write(i)
      cb.close(IO::CircularBuffer::Closed::Write)
    end

    spawn do
      loop do
        count = cb.read(o + read)
        break if count == 0
        read += count
      end

      fiber.resume
    end

    Crystal::Scheduler.reschedule
    assert_equal i, o, "error"
  end

  def test_read_and_write_arbitrary_sized_chunks
    i = Bytes.new(1 * 1024 * 1024) { |i| i.to_u8! }
    o = Bytes.new(1 * 1024 * 1024)
    cb = IO::CircularBuffer.new(64 * 1024)

    fiber = Fiber.current

    spawn do
      count = 0

      loop do
        len = Math.min(rand(1024 .. (16 * 1024)), i.size - count)
        cb.write(i[count, len])
        break if (count += len) == i.size
      end

      cb.close(IO::CircularBuffer::Closed::Write)
    end

    spawn do
      count = 0

      loop do
        len = Math.min(rand(1 .. 1024), i.size - count)
        read = cb.read(o[count, len])
        break if read == 0
        count += read
      end

      fiber.resume
    end

    Crystal::Scheduler.reschedule
    assert_equal i, o, "error"
  end

  def test_copy_to
    cb = IO::CircularBuffer.new(10)
    message = "an incredible message"

    IO.pipe do |r, w|
      r.sync = w.sync = true

      spawn do
        cb << message
        cb.close(IO::CircularBuffer::Closed::Write)
      end

      spawn do
        count = message.size
        until count == 0
          count -= cb.copy_to(w, message.size)
        end
        w.close
      end

      buf = Bytes.new(message.bytesize)
      assert_equal message, r.gets_to_end
    end
  end

  def test_copy_from
    cb = IO::CircularBuffer.new(10)
    message = "an incredible message"

    IO.pipe do |r, w|
      r.sync = w.sync = true

      spawn do
        w.write(message.to_slice)
        w.close
      end

      spawn do
        cb.copy_from(r, message.bytesize)
      end

      buf = Bytes.new(message.bytesize)
      cb.read_fully(buf)
      assert_equal message, String.new(buf)
    end
  end
end
