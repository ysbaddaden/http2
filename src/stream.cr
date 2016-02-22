require "http/headers"
require "./data"

module HTTP2
  record Priority, exclusive, stream_id, weight

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

      def to_s(io)
        case self
        when IDLE
          io << "closed"
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

    getter id : Int32
    getter state : State
    property priority : Priority
    private getter connection : Connection

    def initialize(@connection, @id, @priority = DEFAULT_PRIORITY.dup, @state = State::IDLE : State)
    end

    def data
      @data ||= Data.new
    end

    def headers
      @headers ||= HTTP::Headers.new
    end

    def ==(other : Stream)
      id == other.id
    end

    def ==(other)
      false
    end

    def send_headers(headers, flags = 0)
      payload = connection.hpack_encoder.encode(headers)
      frame = Frame.new(Frame::Type::HEADERS, self, Frame::Flags.new(flags.to_u8))
      max_frame_size = connection.remote_settings.max_frame_size

      if payload.size <= max_frame_size
        frame.flags |= Frame::Flags::END_HEADERS
        frame.payload = payload
        connection.send(frame)
      else
        offset = 0
        while offset < payload.size
          count = offset + max_frame_size > payload.size ? payload.size : max_frame_size
          frame.type = Frame::Type::CONTINUATION if offset > 0
          frame.flags = Frame::Flags::END_HEADERS if count != max_frame_size
          frame.payload = payload[offset, count]
          connection.send(frame)
          offset += count
        end
      end
      nil
    end

    def send_data(data : String, flags = 0)
      send_data(data.to_slice, flags)
    end

    def send_data(data : Slice(UInt8), flags = 0)
      frame = Frame.new(Frame::Type::DATA, self, Frame::Flags.new(flags.to_u8))
      max_frame_size = connection.remote_settings.max_frame_size

      if data.size <= max_frame_size
        frame.payload = data
        connection.send(frame)
      else
        offset = 0
        while offset < data.size
          count = offset + max_frame_size > data.size ? data.size : max_frame_size
          frame.payload = data[offset, count]
          connection.send(frame)
          offset += count
        end
      end
      nil
    end

    def receiving(frame : Frame)
      transition(frame, receiving: true)
    end

    def sending(frame : Frame)
      transition(frame, receiving: false)
    end

    private def transition(frame : Frame, receiving = false)
      return if frame.stream.id == 0
      return if frame.type == Frame::Type::PRIORITY || frame.type == Frame::Type::GOAWAY || frame.type == Frame::Type::PING

      case state
      when State::IDLE
        case frame.type
        when Frame::Type::HEADERS
          self.state = State::OPEN
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
        else
          error!(receiving)
        end

      when State::HALF_CLOSED_LOCAL, State::HALF_CLOSED_REMOTE
        if frame.flags.end_stream? || frame.type == Frame::Type::RST_STREAM
          self.state = State::CLOSED
        end

      when State::CLOSED
        case frame.type
        when Frame::Type::WINDOW_UPDATE, Frame::Type::RST_STREAM
          # ignore
        else
          error!(receiving)
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
      puts "; Stream is now #{state}"
    end
  end
end
