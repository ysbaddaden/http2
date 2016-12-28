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

class Minitest::Test
  include AsyncTest
end
