require "./test_helper"
require "../src/http2"

# Concurrent changes of a stream's state: receiving and sending END_STREAM at
# the same time must close the stream.
class HTTP2::StreamTransitionTest < Minitest::Test
  # Pauses each read of the state while the stream is open, until released.
  class PausingStream < Stream
    getter arrived = Channel(Nil).new(2)
    getter gate = Channel(Nil).new(2)
    property? pausing = false

    def state : State
      state = super
      if pausing? && state.open?
        arrived.send(nil)
        gate.receive
      end
      state
    end
  end

  def test_receiving_and_sending_end_stream_at_once_closes_the_stream
    connection = Connection.new(IO::Stapled.new(IO::Memory.new, IO::Memory.new), :server)
    stream = PausingStream.new(connection, 1, state: Stream::State::OPEN)
    stream.pausing = true

    done = Channel(Nil).new(2)
    spawn do
      stream.receiving(Frame.new(Frame::Type::DATA, stream, Frame::Flags::END_STREAM))
      done.send(nil)
    end
    receive_within(stream.arrived)

    spawn do
      stream.sending(Frame.new(Frame::Type::DATA, stream, Frame::Flags::END_STREAM))
      done.send(nil)
    end
    # the sender reads the state too, unless it waits for the receiver
    select
    when stream.arrived.receive
    when timeout(100.milliseconds)
    end

    stream.pausing = false
    2.times { stream.gate.send(nil) }
    2.times { receive_within(done) }
    assert_equal Stream::State::CLOSED, stream.state
  end

  def test_abort_during_a_transition_keeps_the_stream_closed
    connection = Connection.new(IO::Stapled.new(IO::Memory.new, IO::Memory.new), :server)
    stream = PausingStream.new(connection, 1, state: Stream::State::OPEN)
    stream.pausing = true

    done = Channel(Nil).new(2)
    spawn do
      stream.receiving(Frame.new(Frame::Type::DATA, stream, Frame::Flags::END_STREAM))
      done.send(nil)
    end
    receive_within(stream.arrived)
    spawn do
      stream.abort
      done.send(nil)
    end
    select
    when stream.arrived.receive
    when timeout(100.milliseconds)
    end

    stream.pausing = false
    2.times { stream.gate.send(nil) }
    2.times { receive_within(done) }
    assert_equal Stream::State::CLOSED, stream.state
  end

  private def receive_within(channel, span = 5.seconds)
    select
    when value = channel.receive
      value
    when timeout(span)
      flunk "timed out"
    end
  end
end
