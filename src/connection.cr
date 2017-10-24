require "colorize"
require "logger"
require "./config"
require "./errors"
require "./frame"
require "./hpack"
require "./settings"
require "./streams"

class Logger::Dummy
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
    private getter io : IO #::FileDescriptor | OpenSSL::SSL::Socket

    getter hpack_encoder : HPACK::Encoder
    getter hpack_decoder : HPACK::Decoder

    @logger : Logger|Logger::Dummy|Nil

    def initialize(@io, @logger = nil)
      @local_settings = DEFAULT_SETTINGS.dup
      @remote_settings = Settings.new
      @channel = Channel::Buffered(Frame | Array(Frame) | Nil).new
      @closed = false

      @hpack_encoder = HPACK::Encoder.new(
        max_table_size: local_settings.header_table_size,
        indexing: HPACK::Indexing::NONE,
        huffman: true)
      @hpack_decoder = HPACK::Decoder.new(
        max_table_size: remote_settings.header_table_size)

      spawn frame_writer
    end

    def streams
      # FIXME: thread safety?
      #        can't be in #initialize because of self reference
      @streams ||= Streams.new(self)
    end

    def logger
      @logger ||= Logger::Dummy.new
    end

    def logger=(@logger)
    end

    private def frame_writer
      loop do
        begin
          # OPTIMIZE: follow stream priority to send frames
          if frame = @channel.receive
            case frame
            when Array
              frame.each { |f| write(f, flush: false) }
              io.flush
            else
              write(frame)
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
      return unless frame = read_frame
      stream = frame.stream
      stream.receiving(frame) unless frame.type == Frame::Type::PUSH_PROMISE

      case frame.type
      when Frame::Type::DATA
        raise Error.protocol_error if stream.id == 0
        read_padded(frame) do |len|
          io.read_fully(buf = Slice(UInt8).new(len))
          stream.data.write(buf)

          if frame.flags.end_stream?
            stream.data.close_write
            if content_length = stream.headers["content-length"]?
              # TODO: how to convey the error to the request handler?
              raise Error.protocol_error("MALFORMED data frame") unless content_length.to_i == stream.data.size
            end
          end
        end

      when Frame::Type::HEADERS
        raise Error.protocol_error if stream.id == 0
        read_padded(frame) do |len|
          if frame.flags.priority?
            exclusive, dep_stream_id = read_stream_id
            raise Error.protocol_error("INVALID stream dependency") if stream.id == dep_stream_id
            weight = read_byte.to_i32 + 1
            stream.priority = Priority.new(exclusive == 1, dep_stream_id, weight)
            logger.debug { "  #{stream.priority.debug}" }
            len -= 5
          end

          if stream.data? && !frame.flags.end_stream?
            raise Error.protocol_error("INVALID trailer part")
          end

          io.read_fully(buf = Slice(UInt8).new(len))
          buf = read_headers_payload(frame, buf.to_unsafe, len)

          begin
            if stream.data?
              hpack_decoder.decode(buf, stream.trailing_headers)
            else
              hpack_decoder.decode(buf, stream.headers)
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
              # TODO: how to convey the error to the request handler?
              raise Error.protocol_error("MALFORMED data frame") unless content_length.to_i == stream.data.size
            end
          end
        end

      when Frame::Type::PUSH_PROMISE
        raise Error.protocol_error if stream.id == 0
        read_padded(frame) do |len|
          _, promised_stream_id = read_stream_id
          streams.find(promised_stream_id).receiving(frame)

          len -= 4
          io.read_fully(buf = Slice(UInt8).new(len))
          buf = read_headers_payload(frame, buf.to_unsafe, len)
          hpack_decoder.decode(buf, stream.headers)
        end

      when Frame::Type::PRIORITY
        raise Error.protocol_error if stream.id == 0
        raise Error.frame_size_error unless frame.size == PRIORITY_FRAME_SIZE
        exclusive, dep_stream_id = read_stream_id
        raise Error.protocol_error("INVALID stream dependency") if stream.id == dep_stream_id
        weight = read_byte.to_i32 + 1
        stream.priority = Priority.new(exclusive == 1, dep_stream_id, weight)
        logger.debug { "  #{stream.priority.debug}" }

      when Frame::Type::RST_STREAM
        raise Error.protocol_error if stream.id == 0
        raise Error.frame_size_error unless frame.size == RST_STREAM_FRAME_SIZE
        error_code = Error::Code.new(io.read_bytes(UInt32, IO::ByteFormat::BigEndian))
        logger.debug { "  code=#{error_code.to_s}" }

      when Frame::Type::SETTINGS
        raise Error.protocol_error unless stream.id == 0
        raise Error.frame_size_error unless frame.size % 6 == 0
        unless frame.flags.ack?
          remote_settings.parse(io, frame.size / 6) do |id, value|
            logger.debug { "  #{id}=#{value}" }
            if id == Settings::Identifier::HEADER_TABLE_SIZE
              hpack_decoder.max_table_size = value
            end
          end
          send Frame.new(Frame::Type::SETTINGS, frame.stream, 0x1)
        end

      when Frame::Type::PING
        raise Error.protocol_error unless stream.id == 0
        raise Error.frame_size_error unless frame.size == PING_FRAME_SIZE
        io.read_fully(buf = Slice(UInt8).new(frame.size))
        send Frame.new(Frame::Type::PING, streams.find(0), 1, buf) unless frame.flags.ack?

      when Frame::Type::GOAWAY
        _, last_stream_id = read_stream_id
        error_code = Error::Code.from_value(io.read_bytes(UInt32, IO::ByteFormat::BigEndian))
        io.read_fully(buf = Slice(UInt8).new(frame.size - 8))
        error_message = String.new(buf)

        close(notify: false)
        logger.debug { "  code=#{error_code.to_s}" }

        unless error_code == Error::Code::NO_ERROR
          raise ClientError.new(error_code, last_stream_id, error_message)
        end

      when Frame::Type::WINDOW_UPDATE
        raise Error.frame_size_error unless frame.size == WINDOW_UPDATE_FRAME_SIZE
        buf = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
        #reserved = buf.bit(31)
        window_size_increment = (buf & 0x7fffffff_u32).to_i32
        raise Error.protocol_error unless MINIMUM_WINDOW_SIZE <= window_size_increment <= MAXIMUM_WINDOW_SIZE

        logger.debug { "  WINDOW_SIZE_INCREMENT=#{window_size_increment}" }
        stream.increment_window_size(window_size_increment)

        unless stream.increment_window_size(window_size_increment)
          raise Error.flow_control_error if stream.id == 0
          stream.send_rst_stream(Error::Code::FLOW_CONTROL_ERROR)
        end

      when Frame::Type::CONTINUATION
        Error.protocol_error("UNEXPECTED continuation frame")

      else
        io.skip(frame.size)
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

    private def read_frame
      buf = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      size, type = buf >> 8, buf & 0xff
      flags = read_byte
      _, stream_id = read_stream_id

      if size > remote_settings.max_frame_size
        raise Error.frame_size_error
      end

      unless frame_type = Frame::Type.from_value?(type)
        logger.warn { "UNSUPPORTED FRAME 0x#{type.to_s(16)}" }
        io.skip(size)
        return
      end

      unless frame_type.priority? || streams.valid?(stream_id)
        raise Error.protocol_error("INVALID stream_id ##{stream_id}")
      end
      stream = streams.find(stream_id, consume: !frame_type.priority?)
      frame = Frame.new(frame_type, stream, flags, size: size)
      logger.debug { "recv #{frame.debug(color: :light_cyan)}" }

      frame
    end

    private def read_headers_payload(frame, ptr : UInt8*, len)
      stream = frame.stream

      loop do
        break if frame.flags.end_headers?
        raise Error.protocol_error("EXPECTED continuation frame") unless frame = read_frame
        raise Error.protocol_error("EXPECTED continuation frame") unless frame.type == Frame::Type::CONTINUATION
        raise Error.protocol_error("EXPECTED continuation frame for stream ##{stream.id} not ##{frame.stream.id}") unless frame.stream == stream
        # FIXME: raise if the payload grows too big

        ptr = ptr.realloc(len + frame.size)
        io.read_fully(Slice(UInt8).new(ptr + len, frame.size))
        len += frame.size
      end

      ptr.to_slice(len)
    end

    # Sends a frame to the connected peer.
    #
    # One may also send an Array(Frame) for the case when some frames must be
    # sliced (in order to respect max frame size) but must be sent as a single
    # block (multiplexing would cause a protocol error). So far this only
    # applies to HEADERS and CONTINUATION frames, otherwise HPACK compression
    # synchronisation could end up corrupted if another HEADERS frame for
    # another stream was sent in between.
    def send(frame : Frame | Array(Frame))
      @channel.send(frame)
    end

    def write_settings
      send Frame.new(HTTP2::Frame::Type::SETTINGS, streams.find(0), 0, local_settings.to_payload)
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
