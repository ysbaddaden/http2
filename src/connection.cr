require "./config"
require "./errors"
require "./frame"
require "./hpack"
require "./settings"
require "./stream"
require "colorize"

module HTTP2
  DEFAULT_SETTINGS = Settings.new(
    max_concurrent_streams: 100,
    max_header_list_size: 16384,
  )

  class Connection
    property local_settings : Settings
    property remote_settings : Settings
    private getter io : IO::FileDescriptor | OpenSSL::SSL::Socket
    private getter streams : Hash(Int32, Stream)

    def initialize(@io)
      @local_settings = DEFAULT_SETTINGS.dup
      @remote_settings = Settings.new
      @streams = {} of Int32 => Stream
      @stream_id_counter = 0
      @closed = false
      @channel = Channel::Buffered(Frame | Array(Frame) | Nil).new

      spawn frame_writer
    end

    private def frame_writer
      loop do
        begin
          # OPTIMIZE: follow stream priority to send frames
          # TODO: respect flow-control (don't push DATA frames until window size is sufficient).
          if frame = @channel.receive
            case frame
            when Array
              frame.each { |f| write(f) }
            else
              write(frame)
            end
          else
            break
          end
        rescue Channel::ClosedError
          break
        rescue ex
          puts "#{ex.class.name} #{ex.message}:\n#{ex.backtrace.join(", ")}"
        end
      end
    end

    def hpack_encoder
      @hpack_encoder ||= HPACK::Encoder.new(
        max_table_size: local_settings.header_table_size,
        indexing: HPACK::Indexing::NONE,
        huffman: true)
    end

    def hpack_decoder
      @hpack_decoder ||= HPACK::Decoder.new(
        max_table_size: remote_settings.header_table_size)
    end

    protected def find_or_create_stream(id)
      # FIXME: thread safety
      # TODO: verify that streams are within max_concurrent_streams setting
      streams[id] ||= Stream.new(self, id)
    end

    protected def create_stream(state = Stream::State::IDLE)
      # FIXME: thread safety
      # TODO: verify that streams are within max_concurrent_streams setting
      id = @stream_id_counter += 2
      raise Error.internal_error("STREAM #{id} already exists") if streams[id]?
      streams[id] = Stream.new(self, id, state: state)
    end

    def read_client_preface(truncated = false)
      if truncated
        io.read_fully(buf = Slice(UInt8).new(8))
        raise Error.protocol_error("PREFACE expected") unless String.new(buf) == CLIENT_PREFACE[-8, 8]
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
        read_padded(frame) do |len|
          io.read_fully(buf = Slice(UInt8).new(len))
          stream.data.write(buf)
          stream.data.close_write if frame.flags.end_stream?
        end

      when Frame::Type::HEADERS
        read_padded(frame) do |len|
          if frame.flags.priority?
            exclusive, dep_stream_id = read_stream_id
            weight = read_byte.to_i32 + 1
            stream.priority = Priority.new(exclusive == 1, dep_stream_id, weight)
            len -= 5
          end

          io.read_fully(buf = Slice(UInt8).new(len))
          buf = read_headers_payload(buf.to_unsafe, len) unless frame.flags.end_headers?
          hpack_decoder.decode(buf, stream.headers)
        end

      when Frame::Type::PUSH_PROMISE
        read_padded(frame) do |len|
          _, promised_stream_id = read_stream_id
          find_or_create_stream(promised_stream_id).receiving(frame)

          len -= 4
          io.read_fully(buf = Slice(UInt8).new(len))
          buf = read_headers_payload(buf.to_unsafe, len) unless frame.flags.end_headers?
          hpack_decoder.decode(buf, stream.headers)
        end

      when Frame::Type::PRIORITY
        exclusive, dep_stream_id = read_stream_id
        weight = read_byte.to_i32 + 1
        stream.priority = Priority.new(exclusive == 1, dep_stream_id, weight)

      when Frame::Type::RST_STREAM
        raise Error.protocol_error if stream.id == 0
        raise Error.frame_size_error unless frame.size == RST_STREAM_FRAME_SIZE
        error_code = Error::Code.new(read_byte.to_u32)

      when Frame::Type::SETTINGS
        raise Error.protocol_error unless stream.id == 0
        raise Error.frame_size_error unless frame.size % 6 == 0
        unless frame.flags.ack?
          remote_settings.parse(io, frame.size / 6)
          write Frame.new(Frame::Type::SETTINGS, frame.stream, 0x1)
        end

      when Frame::Type::PING
        raise Error.protocol_error unless stream.id == 0
        raise Error.frame_size_error unless frame.size == PING_FRAME_SIZE
        io.read_fully(buf = Slice(UInt8).new(frame.size))
        write Frame.new(Frame::Type::PING, find_or_create_stream(0), 1, buf) unless frame.flags.ack?

      when Frame::Type::GOAWAY
        _, last_stream_id = read_stream_id
        error_code = Error::Code.from_value(io.read_bytes(UInt32, IO::ByteFormat::BigEndian))
        io.read_fully(buf = Slice(UInt8).new(frame.size - 8))
        error_message = String.new(buf)

        close(notify: false)

        unless error_code == Error::Code::NO_ERROR
          raise ClientError.new(error_code, last_stream_id, error_message)
        end

      #when Frame::Type::WINDOW_UPDATE
      #  raise Error.frame_size_error unless frame.size == WINDOW_UPDATE_FRAME_SIZE
      #  buf = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      #  #reserved = buf.bit(31)
      #  window_size_increment = (buf & 0x7fffffff_u32).to_i32
      #  raise Error.protocol_error unless MINIMUM_WINDOW_SIZE <= window_size_increment < MAXIMUM_WINDOW_SIZE

      #  if stream.id == 0
      #    @window_size = window_size_increment
      #  else
      #    stream.window_size = window_size_increment
      #  end

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

      unless frame_type = Frame::Type.from_value?(type)
        puts "UNSUPPORTED FRAME 0x#{type.to_s(16)}"
        io.skip(size)
        return
      end

      stream = find_or_create_stream(stream_id)
      frame = Frame.new(frame_type, stream, flags, size: size)
      puts "recv #{frame.debug(color: :light_cyan)}"

      frame
    end

    private def read_headers_payload(ptr : UInt8*, len)
      loop do
        raise Error.protocol_error("EXPECTED continuation frame") unless frame = read_frame
        raise Error.protocol_error("EXPECTED continuation frame") unless frame.type == Frame::Type::CONTINUATION
        raise Error.protocol_error("EXPECTED continuation frame") unless frame.stream == frame.stream
        # FIXME: raise if the payload grows too big

        ptr = ptr.realloc(len + frame.size)
        io.read_fully(Slice(UInt8).new(ptr + len, frame.size))
        len += frame.size

        break if frame.flags.end_headers?
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
      write Frame.new(HTTP2::Frame::Type::SETTINGS, find_or_create_stream(0), 0, local_settings.to_payload)
    end

    protected def write(frame : Frame)
      size = frame.payload?.try(&.size.to_u32) || 0_u32
      stream = frame.stream

      puts "send #{frame.debug(color: :light_magenta)}"
      stream.sending(frame) unless frame.type == Frame::Type::PUSH_PROMISE

      io.write_bytes((size << 8) | frame.type.to_u8, IO::ByteFormat::BigEndian)
      io.write_byte(frame.flags.to_u8)
      io.write_bytes(stream.id.to_u32, IO::ByteFormat::BigEndian)

      if payload = frame.payload?
        io.write(payload) if payload.size > 0
      end
    end

    def close(error = nil, notify = true)
      return if closed?
      @closed = true

      #unless io.closed?
        if notify
          if error
            message, code = error.message, error.code
          else
            message, code = "", Error::Code::NO_ERROR
          end
          payload = MemoryIO.new(8 + message.bytesize)
          payload.write_bytes(last_stream_id.to_u32, IO::ByteFormat::BigEndian)
          payload.write_bytes(code.to_u32, IO::ByteFormat::BigEndian)
          payload << message
          write Frame.new(Frame::Type::GOAWAY, find_or_create_stream(0), 0, payload.to_slice)
        end
        io.close
      #end

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

    private def last_stream_id
      if streams.any?
        streams.keys.max
      else
        0
      end
    end
  end
end
