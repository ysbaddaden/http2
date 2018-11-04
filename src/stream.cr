require "http/headers"
require "./data"

module HTTP2
  class Priority
    property exclusive : Bool
    property dep_stream_id : Int32
    property weight : Int32

    def initialize(@exclusive : Bool, @dep_stream_id : Int32, @weight : Int32)
    end

    # :nodoc:
    def debug
      "exclusive=#{exclusive} dep_stream_id=#{dep_stream_id} weight=#{weight}"
    end
  end

  DEFAULT_PRIORITY = Priority.new(false, 0, 16)

  class Stream
    enum State
      IDLE
      RESERVED_LOCAL
      RESERVED_REMOTE
      OPEN
      HALF_CLOSED_LOCAL
      HALF_CLOSED_REMOTE
      CLOSED

      # :nodoc:
      def to_s(io)
        case self
        when IDLE
          io << "idle"
        when RESERVED_LOCAL
          io << "reserved (local)"
        when RESERVED_REMOTE
          io << "reserved (remote)"
        when OPEN
          io << "open"
        when HALF_CLOSED_LOCAL
          io << "half-closed (local)"
        when HALF_CLOSED_REMOTE
          io << "half-closed (remote)"
        when CLOSED
          io << "closed"
        end
      end
    end

    # The stream identifier. Odd-numbered for client streams (requests),
    # even-numbered for server initiated streams (server-push).
    getter id : Int32
    getter state : State
    property priority : Priority
    private getter connection : Connection
    protected getter outbound_window_size : Int32

    # :nodoc:
    protected def initialize(@connection, @id, @priority = DEFAULT_PRIORITY.dup, @state = State::IDLE)
      @outbound_window_size = connection.remote_settings.initial_window_size
    end

    # Returns true if the stream is in an active `#state`, that is OPEN or
    # HALF_CLOSED (local or remote).
    def active? : Bool
      state == State::OPEN ||
      state == State::HALF_CLOSED_LOCAL ||
      state == State::HALF_CLOSED_REMOTE
    end

    # Returns true if any DATA was received, false otherwise.
    #
    # FIXME: reports `false` if a zero-sized DATA was received.
    protected def data? : Bool
      data.size != 0
    end

    # Received body.
    #
    # Implemented as a circular buffer that acts as an `IO`. Reading a request
    # body will block if the buffer is emptied, and will be resumed when the
    # connected peer sends more DATA frames.
    #
    # See `Data` for more details.
    def data : Data
      @data ||= Data.new(self, connection.local_settings.initial_window_size)
    end

    # Received HTTP headers. In a server context they are headers of the
    # received client request; in a client context they are headers of the
    # received server response.
    def headers : HTTP::Headers
      @headers ||= HTTP::Headers.new
    end

    # Received trailing headers, or `nil` if none have been received (yet).
    def trailing_headers? : HTTP::Headers?
      @trailing_headers
    end

    protected def trailing_headers : HTTP::Headers
      @trailing_headers ||= HTTP::Headers.new
    end

    def ==(other : Stream)
      id == other.id
    end

    def ==(other)
      false
    end

    protected def increment_outbound_window_size(increment) : Nil
      if @outbound_window_size.to_i64 + increment > MAXIMUM_WINDOW_SIZE
        send_rst_stream(Error::Code::FLOW_CONTROL_ERROR)
        return
      end
      @outbound_window_size += increment
      resume_writeable
    end

    protected def consume_outbound_window_size(size)
      @outbound_window_size -= size
    end

    protected def send_window_update_frame(increment)
      unless MINIMUM_WINDOW_SIZE <= increment <= MAXIMUM_WINDOW_SIZE
        raise Error.protocol_error("invalid WINDOW_UPDATE increment: #{increment}")
      end
      io = IO::Memory.new(WINDOW_UPDATE_FRAME_SIZE)
      io.write_bytes(increment.to_u32 & 0x7fffffff_u32, IO::ByteFormat::BigEndian)
      connection.send Frame.new(Frame::Type::WINDOW_UPDATE, self, payload: io.to_slice)
    end

    # Sends a PRIORITY frame for the current `#priority` definition.
    #
    # This may only be sent by a client, to hint the server to prioritize some
    # streams over others. The server may or may not respect the expected
    # priorities.
    def send_priority : Nil
      exclusive = priority.exclusive ? 0x80000000_u32 : 0_u32
      dep_stream_id = priority.dep_stream_id.to_u32 & 0x7fffffff_u32

      io = IO::Memory.new(PRIORITY_FRAME_SIZE)
      io.write_bytes(exclusive | dep_stream_id, IO::ByteFormat::BigEndian)
      io.write_byte((priority.weight - 1).to_u8)

      connection.send Frame.new(Frame::Type::PRIORITY, self, payload: io.to_slice)
    end

    # Sends `HTTP::Headers` as part of a response or request.
    #
    # This will send a HEADERS frame, possibly followed by CONTINUATION frames.
    # The `Frame::Flags::END_HEADERS` flag will be automatically set on the last
    # part; hence you can't send headers multiple times.
    def send_headers(headers : HTTP::Headers, flags : Frame::Flags = Frame::Flags::None) : Nil
      payload = connection.hpack_encoder.encode(headers)
      send_headers(Frame::Type::HEADERS, headers, flags, payload)
    end

    # Sends `HTTP::Headers` as a server-push request.
    #
    # Creates a server initiated stream (even numbered) as the promised stream,
    # that is the stream that shall be used to push the server-pushed response
    # headers and data.
    #
    # This will send a PUSH_PROMISE frame to the expected stream. If the client
    # doesn't want the server-push or already has it cached, it may refuse the
    # server-push request by closing the promised stream immediately.
    #
    # Returns the promised stream, or `nil` if the client configured
    # SETTINGS_ENABLE_PUSH to be false (true by default).
    #
    # You may send multiple PUSH_PROMISE frames on an expected stream, but you
    # may send only one per resource to push.
    def send_push_promise(headers : HTTP::Headers, flags : Frame::Flags = Frame::Flags::None) : Stream?
      unless connection.remote_settings.enable_push
        return
      end
      connection.streams.create(state: Stream::State::RESERVED_LOCAL).tap do |stream|
        io = IO::Memory.new
        io.write_bytes(stream.id.to_u32 & 0x7fffffff_u32, IO::ByteFormat::BigEndian)
        payload = connection.hpack_encoder.encode(headers, writer: io)
        send_headers(Frame::Type::PUSH_PROMISE, headers, flags, payload)
      end
    end

    protected def send_headers(type : Frame::Type, headers, flags, payload) : Nil
      max_frame_size = connection.remote_settings.max_frame_size

      if payload.size <= max_frame_size
        flags |= flags | Frame::Flags::END_HEADERS
        frame = Frame.new(type, self, flags, payload)
        connection.send(frame)
      else
        num = (payload.size / max_frame_size.to_f).ceil.to_i
        count = max_frame_size
        offset = 0

        frames = num.times.map do |index|
          type = Frame::Type::CONTINUATION if index > 1
          offset = index * max_frame_size
          if index == num
            count = payload.size - offset
            flags |= Frame::Flags::END_HEADERS
          end
          Frame.new(type, self, flags, payload[offset, count])
        end

        connection.send(frames.to_a)
      end
    end

    # Writes data to the stream.
    #
    # This may be part of a request body (client context), or a response body
    # (server context).
    #
    # This will send one or many DATA frames, respecting SETTINGS_MAX_FRAME_SIZE
    # as defined by the remote peer, as well as available window sizes for the
    # stream and the connection, exhausting them as much as possible.
    #
    # This will block the current fiber if *data* is too big than allowed by any
    # window size (stream or connection). The fiber will be eventually resumed
    # when the remote peer sends a WINDOW_UPDATE frame to increment window
    # sizes.
    #
    # Eventually returns when *data* has been fully sent.
    def send_data(data : String, flags : Frame::Flags = Frame::Flags::None) : Nil
      send_data(data.to_slice, flags)
    end

    # ditto
    def send_data(data : Bytes, flags : Frame::Flags = Frame::Flags::None) : Nil
      if flags.end_stream? && data.size > 0
        end_stream = true
        flags ^= Frame::Flags::END_STREAM
      else
        end_stream = false
      end

      frame = Frame.new(Frame::Type::DATA, self, flags)

      if data.size == 0
        connection.send(frame)
        return
      end

      until data.size == 0
        if @outbound_window_size < 1 || connection.outbound_window_size < 1
          wait_writeable
        end

        size = {data.size, @outbound_window_size, connection.remote_settings.max_frame_size}.min
        if size > 0
          actual = connection.consume_outbound_window_size(size)

          if actual > 0
            frame.payload = data[0, actual]

            consume_outbound_window_size(actual)
            data += actual

            frame.flags |= Frame::Flags::END_STREAM if data.size == 0 && end_stream
            connection.send(frame)
          end
        end

        # allow other fibers to do their job (e.g. let the connection send or
        # receive frames, let other streams send data, ...)
        Fiber.yield
      end
    end

    # Block current fiber until the stream can send data. I.e. it's window size
    # or the connection window size have been increased.
    private def wait_writeable
      @fiber = Fiber.current
      Crystal::Scheduler.reschedule
    ensure
      @fiber = nil
    end

    # Resume a previously paused fiber waiting to send data, if any.
    protected def resume_writeable
      if (fiber = @fiber) && @outbound_window_size > 0
        Crystal::Scheduler.enqueue(Fiber.current)
        fiber.resume
      end
    end

    # Closes the stream. Optionally reporting an error status.
    def send_rst_stream(error_code : Error::Code) : Nil
      io = IO::Memory.new(RST_STREAM_FRAME_SIZE)
      io.write_bytes(error_code.value.to_u32, IO::ByteFormat::BigEndian)
      connection.send Frame.new(Frame::Type::RST_STREAM, self, payload:  io.to_slice)
    end

    protected def receiving(frame : Frame)
      transition(frame, receiving: true)
    end

    protected def sending(frame : Frame)
      transition(frame, receiving: false)
    end

    private NON_TRANSITIONAL_FRAMES = [
      Frame::Type::PRIORITY,
      Frame::Type::GOAWAY,
      Frame::Type::PING,
    ]

    private def transition(frame : Frame, receiving = false)
      return if frame.stream.id == 0 || NON_TRANSITIONAL_FRAMES.includes?(frame.type)

      case state
      when State::IDLE
        case frame.type
        when Frame::Type::HEADERS
          self.state = frame.flags.end_stream? ? State::HALF_CLOSED_REMOTE : State::OPEN
        when Frame::Type::PUSH_PROMISE
          self.state = receiving ? State::RESERVED_REMOTE : State::RESERVED_LOCAL
        else
          error!(receiving)
        end

      when State::RESERVED_LOCAL
        error!(receiving) if receiving

        case frame.type
        when Frame::Type::HEADERS
          self.state = State::HALF_CLOSED_LOCAL
        when Frame::Type::RST_STREAM
          self.state = State::CLOSED
        else
          error!(receiving)
        end

      when State::RESERVED_REMOTE
        error!(receiving) unless receiving

        case frame.type
        when Frame::Type::HEADERS
          self.state = State::HALF_CLOSED_REMOTE
        when Frame::Type::RST_STREAM
          self.state = State::CLOSED
        else
          error!(receiving)
        end

      when State::OPEN
        case frame.type
        when Frame::Type::HEADERS, Frame::Type::DATA
          if frame.flags.end_stream?
            self.state = receiving ? State::HALF_CLOSED_REMOTE : State::HALF_CLOSED_LOCAL
          end
        when Frame::Type::RST_STREAM
          self.state = State::CLOSED
        when Frame::Type::WINDOW_UPDATE
          # ignore
        else
          error!(receiving)
        end

      when State::HALF_CLOSED_LOCAL
        #if sending
        #  case frame.type
        #  when Frame::Type::HEADERS, Frame::Type::CONTINUATION, Frame::Type::DATA
        #    raise Error.stream_closed("STREAM #{id} is #{state}")
        #  end
        #end
        if frame.flags.end_stream? || frame.type == Frame::Type::RST_STREAM
          self.state = State::CLOSED
        end

      when State::HALF_CLOSED_REMOTE
        if receiving
          case frame.type
          when Frame::Type::HEADERS, Frame::Type::CONTINUATION, Frame::Type::DATA
            raise Error.stream_closed("STREAM #{id} is #{state}")
          end
        end
        if frame.flags.end_stream? || frame.type == Frame::Type::RST_STREAM
          self.state = State::CLOSED
        end

      when State::CLOSED
        case frame.type
        when Frame::Type::WINDOW_UPDATE, Frame::Type::RST_STREAM
          # ignore
        else
          if receiving
            raise Error.stream_closed("STREAM #{id} is #{state}")
          else
            raise Error.internal_error("STREAM #{id} is #{state}")
          end
        end
      end
    end

    private def error!(receiving = false)
      if receiving
        raise Error.protocol_error("STREAM #{id} is #{state}")
      else
        raise Error.internal_error("STREAM #{id} is #{state}")
      end
    end

    private def state=(@state)
      connection.logger.debug { "; Stream is now #{state}" }
    end

    # :nodoc:
    def hash(hasher)
      id.hash(hasher)
    end
  end
end
