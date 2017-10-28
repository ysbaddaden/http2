require "colorize"
require "logger"
require "./config"
require "./errors"
require "./frame"
require "./hpack"
require "./settings"
require "./streams"

class Logger::Dummy < Logger
  {% for name in Logger::Severity.constants %}
    def {{ name.downcase }}?
      false
    end

    def {{ name.downcase }}(message)
    end

    def {{ name.downcase }}(&block)
    end
  {% end %}
end

module HTTP2
  DEFAULT_SETTINGS = Settings.new(
    max_concurrent_streams: 100,
    max_header_list_size: 16384,
  )

  class Connection
    property local_settings : Settings
    property remote_settings : Settings
    private getter io : IO

    getter hpack_encoder : HPACK::Encoder
    getter hpack_decoder : HPACK::Decoder

    @logger : Logger?

    def initialize(@io, @logger = nil)
      @local_settings = DEFAULT_SETTINGS.dup
      @remote_settings = Settings.new
      @channel = Channel::Buffered(Frame | Array(Frame) | Nil).new
      @closed = false

      @hpack_encoder = HPACK::Encoder.new(
        max_table_size: local_settings.header_table_size,
        indexing: HPACK::Indexing::NONE,
        huffman: true
      )
      @hpack_decoder = HPACK::Decoder.new(
        max_table_size: remote_settings.header_table_size
      )

      @inbound_window_size = DEFAULT_INITIAL_WINDOW_SIZE
      @outbound_window_size = Atomic(Int32).new(DEFAULT_INITIAL_WINDOW_SIZE)

      spawn frame_writer
    end

    def streams
      # FIXME: thread safety?
      #        can't be in #initialize because of self reference
      @streams ||= Streams.new(self)
    end

    def logger
      @logger ||= Logger::Dummy.new(File.open("/dev/null"))
    end

    def logger=(@logger)
    end

    private def frame_writer
      loop do
        begin
          # OPTIMIZE: follow stream priority to send frames
          if frame = @channel.receive
            begin
              case frame
              when Array
                frame.each do |f|
                  write(f, flush: false)
                end
              else
                write(frame, flush: false)
              end
            ensure
              # flush pending frames when there are no more frames to send,
              # otherwise let IO::Buffered do its job:
              io.flush if @channel.empty?
            end
          else
            io.close unless io.closed?
            break
          end
        rescue Channel::ClosedError
          break
        rescue ex
          #logger.debug { "#{ex.class.name} #{ex.message}:\n#{ex.backtrace.join('\n')}" }
          logger.debug { "ERROR: #{ex.class.name} #{ex.message}" }
        end
      end
    end

    def read_client_preface(truncated = false)
      if truncated
        io.read_fully(buf = Slice(UInt8).new(6))
        raise Error.protocol_error("PREFACE expected") unless String.new(buf) == CLIENT_PREFACE[-6, 6]
      else
        io.read_fully(buf = Slice(UInt8).new(24))
        raise Error.protocol_error("PREFACE expected") unless String.new(buf) == CLIENT_PREFACE
      end
    end

    def receive
      frame = read_frame_header
      stream = frame.stream

      stream.receiving(frame)

      case frame.type
      when Frame::Type::DATA
        raise Error.protocol_error if stream.id == 0
        read_data_frame(frame)

      when Frame::Type::HEADERS
        raise Error.protocol_error if stream.id == 0
        read_headers_frame(frame)

      when Frame::Type::PUSH_PROMISE
        raise Error.protocol_error if stream.id == 0
        read_push_promise_frame(frame)

      when Frame::Type::PRIORITY
        raise Error.protocol_error if stream.id == 0
        read_priority_frame(frame)

      when Frame::Type::RST_STREAM
        raise Error.protocol_error if stream.id == 0
        read_rst_stream_frame(frame)

      when Frame::Type::SETTINGS
        raise Error.protocol_error unless stream.id == 0
        read_settings_frame(frame)

      when Frame::Type::PING
        raise Error.protocol_error unless stream.id == 0
        read_ping_frame(frame)

      when Frame::Type::GOAWAY
        read_goaway_frame(frame)

      when Frame::Type::WINDOW_UPDATE
        read_window_update_frame(frame)

      when Frame::Type::CONTINUATION
        raise Error.protocol_error("UNEXPECTED CONTINUATION frame")

      else
        skip_unsupported_frame(frame)
      end

      frame
    end

    private def read_padded(frame)
      size = frame.size

      if frame.flags.padded?
        pad_size = read_byte
        size -= 1 + pad_size
      end

      raise Error.protocol_error("INVALID pad length") if size < 0

      yield size

      if pad_size
        io.skip(pad_size)
      end
    end

    private def read_frame_header
      buf = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      size, type = buf >> 8, buf & 0xff
      flags = read_byte
      _, stream_id = read_stream_id

      if size > remote_settings.max_frame_size
        raise Error.frame_size_error
      end

      frame_type = Frame::Type.new(type.to_i)
      unless frame_type.priority? || streams.valid?(stream_id)
        raise Error.protocol_error("INVALID stream_id ##{stream_id}")
      end

      stream = streams.find(stream_id, consume: !frame_type.priority?)
      frame = Frame.new(frame_type, stream, flags, size: size)

      logger.debug { "recv #{frame.debug(color: :light_cyan)}" }

      frame
    end

    private def read_data_frame(frame)
      stream = frame.stream

      read_padded(frame) do |size|
        consume_inbound_window_size(size)

        #buffer = Bytes.new(size)
        #io.read_fully(buffer)
        #stream.data.write(buffer)
        stream.data.copy_from(io, size)

        if frame.flags.end_stream?
          stream.data.close_write

          if content_length = stream.headers["content-length"]?
            unless content_length.to_i == stream.data.size
              # stream.send_rst_stream(Error::Code::PROTOCOL_ERROR)
              raise Error.protocol_error("MALFORMED data frame")
            end
          end
        end
      end
    end

    private def read_headers_frame(frame)
      stream = frame.stream

      read_padded(frame) do |size|
        if frame.flags.priority?
          exclusive, dep_stream_id = read_stream_id
          raise Error.protocol_error("INVALID stream dependency") if stream.id == dep_stream_id
          weight = read_byte.to_i32 + 1
          stream.priority = Priority.new(exclusive == 1, dep_stream_id, weight)
          logger.debug { "  #{stream.priority.debug}" }
          size -= 5
        end

        if stream.data? && !frame.flags.end_stream?
          raise Error.protocol_error("INVALID trailer part")
        end

        buffer = read_headers_payload(frame, size)

        begin
          if stream.data?
            hpack_decoder.decode(buffer, stream.trailing_headers)
          else
            hpack_decoder.decode(buffer, stream.headers)
          end
        rescue ex : HPACK::Error
          logger.debug { "HPACK::Error: #{ex.message}" }
          raise Error.compression_error
        end

        if stream.data?
          # https://tools.ietf.org/html/rfc7540#section-8.1
          # https://tools.ietf.org/html/rfc7230#section-4.1.2
          stream.data.close_write

          if content_length = stream.headers["content-length"]?
            unless content_length.to_i == stream.data.size
              #connection.send_rst_stream(Error::Code::PROTOCOL_ERROR)
              raise Error.protocol_error("MALFORMED data frame")
            end
          end
        end
      end
    end

    # OPTIMIZE: consider IO::CircularBuffer and decompressing HPACK headers
    # in-parallel instead of reallocating pointers and eventually
    # decompressing everything
    private def read_headers_payload(frame, size)
      stream = frame.stream

      pointer = GC.malloc_atomic(size).as(UInt8*)
      io.read_fully(pointer.to_slice(size))

      loop do
        break if frame.flags.end_headers?

        unless frame.type == Frame::Type::CONTINUATION
          raise Error.protocol_error("EXPECTED continuation frame")
        end
        unless frame.stream == stream
          raise Error.protocol_error("EXPECTED continuation frame for stream ##{stream.id} not ##{frame.stream.id}")
        end

        # FIXME: raise if the payload grows too big
        pointer = pointer.realloc(size + frame.size)
        io.read_fully((pointer + size).to_slice(frame.size))

        size += frame.size
      end

      pointer.to_slice(size)
    end

    private def read_push_promise_frame(frame)
      stream = frame.stream

      read_padded(frame) do |size|
        _, promised_stream_id = read_stream_id
        streams.find(promised_stream_id).receiving(frame)
        buffer = read_headers_payload(frame, size - 4)
        hpack_decoder.decode(buffer, stream.headers)
      end
    end

    private def read_priority_frame(frame)
      stream = frame.stream
      raise Error.frame_size_error unless frame.size == PRIORITY_FRAME_SIZE

      exclusive, dep_stream_id = read_stream_id
      raise Error.protocol_error("INVALID stream dependency") if stream.id == dep_stream_id

      weight = 1 + read_byte
      stream.priority = Priority.new(exclusive == 1, dep_stream_id, weight)

      logger.debug { "  #{stream.priority.debug}" }
    end

    private def read_rst_stream_frame(frame)
      raise Error.frame_size_error unless frame.size == RST_STREAM_FRAME_SIZE
      error_code = Error::Code.new(io.read_bytes(UInt32, IO::ByteFormat::BigEndian))
      logger.debug { "  code=#{error_code.to_s}" }
    end

    private def read_settings_frame(frame)
      raise Error.frame_size_error unless frame.size % 6 == 0
      return if frame.flags.ack?

      remote_settings.parse(io, frame.size / 6) do |id, value|
        logger.debug { "  #{id}=#{value}" }

        case id
        when Settings::Identifier::HEADER_TABLE_SIZE
          hpack_decoder.max_table_size = value

        when Settings::Identifier::INITIAL_WINDOW_SIZE
          difference = value - remote_settings.initial_window_size

          unless difference == 0
            # adjust connection window size
            increment_outbound_window_size(difference)

            # adjust windows size for all control-flow streams
            streams.each do |stream|
              next if stream.id == 0
              stream.increment_outbound_window_size(difference)
            end
          end
        end
      end

      # ACK reception of remote SETTINGS:
      send Frame.new(Frame::Type::SETTINGS, frame.stream, 0x1)
    end

    private def read_ping_frame(frame)
      raise Error.frame_size_error unless frame.size == PING_FRAME_SIZE

      buffer = Bytes.new(frame.size)
      io.read_fully(buffer)

      if frame.flags.ack?
        # TODO: validate buffer == previously sent PING value
      else
        send Frame.new(Frame::Type::PING, frame.stream, 1, buffer)
      end
    end

    private def read_goaway_frame(frame)
      _, last_stream_id = read_stream_id
      error_code = Error::Code.new(io.read_bytes(UInt32, IO::ByteFormat::BigEndian))

      buffer = Bytes.new(frame.size - 8)
      io.read_fully(buffer)
      error_message = String.new(buffer)

      close(notify: false)
      logger.debug { "  code=#{error_code.to_s}" }

      unless error_code == Error::Code::NO_ERROR
        raise ClientError.new(error_code, last_stream_id, error_message)
      end
    end

    private def read_window_update_frame(frame)
      stream = frame.stream

      raise Error.frame_size_error unless frame.size == WINDOW_UPDATE_FRAME_SIZE
      buf = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      # reserved = buf.bit(31)
      window_size_increment = (buf & 0x7fffffff_u32).to_i32
      raise Error.protocol_error unless MINIMUM_WINDOW_SIZE <= window_size_increment <= MAXIMUM_WINDOW_SIZE

      logger.debug { "  WINDOW_SIZE_INCREMENT=#{window_size_increment}" }

      if stream.id == 0
        increment_outbound_window_size(window_size_increment)
      else
        stream.increment_outbound_window_size(window_size_increment)
      end
    end

    private def skip_unsupported_frame(frame)
      io.skip(frame.size)
    end

    # Sends a frame to the connected peer.
    #
    # One may also send an Array(Frame) for the case when some frames must be
    # sliced (in order to respect max frame size) but must be sent as a single
    # block (multiplexing would cause a protocol error). So far this only
    # applies to HEADERS and CONTINUATION frames, otherwise HPACK compression
    # synchronisation could end up corrupted if another HEADERS frame for
    # another stream was sent in between.
    def send(frame : Frame | Array(Frame)) : Nil
      @channel.send(frame) unless @channel.closed?
    end

    def write_settings
      write Frame.new(HTTP2::Frame::Type::SETTINGS, streams.find(0), 0, local_settings.to_payload)
    end

    private def write(frame : Frame, flush = true)
      size = frame.payload?.try(&.size.to_u32) || 0_u32
      stream = frame.stream

      logger.debug { "send #{frame.debug(color: :light_magenta)}" }
      stream.sending(frame) unless frame.type == Frame::Type::PUSH_PROMISE

      io.write_bytes((size << 8) | frame.type.to_u8, IO::ByteFormat::BigEndian)
      io.write_byte(frame.flags.to_u8)
      io.write_bytes(stream.id.to_u32, IO::ByteFormat::BigEndian)

      if payload = frame.payload?
        io.write(payload) if payload.size > 0
      end

      if flush
        io.flush #unless io.sync?
      end
    end

    # Keeps the inbound window size (when receiving DATA frames). If the
    # available size shrinks below half the initial window size, then we send a
    # WINDOW_UPDATE frame to increment it by the initial window size * the
    # number of active streams, respecting `MAXIMUM_WINDOW_SIZE`.
    private def consume_inbound_window_size(len)
      @inbound_window_size -= len
      initial_window_size = local_settings.initial_window_size

      if @inbound_window_size < (initial_window_size / 2)
      #if @inbound_window_size <= 0
        increment = Math.min(initial_window_size * streams.active_count(1), MAXIMUM_WINDOW_SIZE)
        @inbound_window_size += increment
        streams.find(0).send_window_update_frame(increment)
      end
    end

    protected def outbound_window_size
      @outbound_window_size.get
    end

    # Tries to consume *len* bytes from the connection outbound window size, but
    # may return a lower value, or even 0.
    protected def consume_outbound_window_size(len)
      loop do
        window_size = @outbound_window_size.get
        return 0 if window_size == 0

        actual = Math.min(len, window_size)
        _, success = @outbound_window_size.compare_and_set(window_size, window_size - actual)
        return actual if success
      end
    end

    # Increments the connection outbound window size.
    private def increment_outbound_window_size(increment) : Nil
      if outbound_window_size.to_i64 + increment > MAXIMUM_WINDOW_SIZE
        raise Error.flow_control_error
      end
      @outbound_window_size.add(increment)

      if outbound_window_size > 0
        streams.each(&.resume_pending_write)
      end
    end

    def close(error = nil, notify = true)
      return if closed?
      @closed = true

      unless io.closed?
        if notify
          if error
            message, code = error.message || "", error.code
          else
            message, code = "", Error::Code::NO_ERROR
          end
          payload = IO::Memory.new(8 + message.bytesize)
          payload.write_bytes(streams.last_stream_id.to_u32, IO::ByteFormat::BigEndian)
          payload.write_bytes(code.to_u32, IO::ByteFormat::BigEndian)
          payload << message

          # FIXME: shouldn't write directly to IO
          write Frame.new(Frame::Type::GOAWAY, streams.find(0), 0, payload.to_slice)
        end
      end

      unless @channel.closed?
        @channel.send(nil)
        @channel.close
      end
    end

    def closed?
      @closed
    end

    private def read_byte
      io.read_byte.not_nil!
    end

    private def read_stream_id
      buf = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      {buf.bit(31), (buf & 0x7fffffff_u32).to_i32}
    end
  end
end
