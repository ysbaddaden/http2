require "./config"
require "./errors"
require "./frame"
require "./hpack"
require "./settings"

module HTTP2
  DEFAULT_SETTINGS = Settings.new(
    #header_table_size: 0,
    max_concurrent_streams: 100,
    #initial_window_size: 65535,
    max_header_list_size: 16384,
  )

  class Connection
    property local_settings : Settings
    property remote_settings : Settings
    private getter io : IO::FileDescriptor
    private getter streams : Hash(Int32, Priority)

    record Priority, exclusive, stream_id, weight

    def initialize(@io)
      @local_settings = DEFAULT_SETTINGS.dup
      @remote_settings = Settings.new
      @streams = {} of Int32 => Priority
      @closed = false
    end

    def hpack_encoder
      @hpack_encoder ||= HPACK::Encoder.new(
        max_table_size: local_settings.header_table_size,
        indexing: HPACK::Indexing::NONE,
        huffman: true)
    end

    def hpack_decoder
      @hpack_decoder = HPACK::Decoder.new(
        max_table_size: remote_settings.header_table_size)
    end

    def read_client_preface
      io.read_fully(buf = Slice(UInt8).new(24))
      raise Error.protocol_error("PREFACE expected") unless String.new(buf) == CLIENT_PREFACE
    end

    private def padded(frame, length)
      if frame.flags.padded?
        pad_length = read_byte
        length -= 1 + pad_length
      end

      yield length

      if pad_length
        io.skip(pad_length)
      end
    end

    def receive
      length, type, flags, _, stream_id = read_frame_headers
      unless type
        io.skip(length)
        return
      end

      frame = Frame.new(type, stream_id, flags)

      case type
      when Frame::Type::DATA
        padded(frame, length) do |len|
          io.read(frame.payload = Slice(UInt8).new(len))
        end

      when Frame::Type::HEADERS, Frame::Type::PUSH_PROMISE
        padded(frame, length) do |len|
          if frame.flags.priority?
            # TODO: open stream
            exclusive, dep_stream_id = read_stream_id
            weight = read_byte.to_i32 + 1
            streams[frame.stream_id] = Priority.new(exclusive, dep_stream_id, weight)
            len -= 5
          end

          # FIXME: decoding headers is order dependent!
          # OPTIMIZE: decode HPACK directly from IO
          io.read_fully(frame.payload = Slice(UInt8).new(len))

          #if frame.type == Frame::Type::SETTINGS && frame.flags.end_stream?
          #  TODO: half-close stream (remote)
          #end
        end

      #when Frame::Type::PRIORITY
      #  TODO: open stream
      #  streams[frame.stream_id] = Priority.new(*read_stream_id, read_byte.to_i32 + 1)

      #when Frame::Type::RST_STREAM
      #  raise Error.protocol_error if frame.stream_id == 0
      #  raise Error.frame_size_error unless length == RST_STREAM_FRAME_SIZE
      #  error_code = Error::Code.new(read_byte)
      #  TODO: close stream

      when Frame::Type::SETTINGS
        raise Error.protocol_error unless frame.stream_id == 0
        raise Error.frame_size_error unless length % 6 == 0
        remote_settings.parse(io, length / 6)

      when Frame::Type::PING
        raise Error.protocol_error unless frame.stream_id == 0
        raise Error.frame_size_error unless length == PING_FRAME_SIZE
        io.read_fully(buf = Slice(UInt8).new(length))
        write Frame.new(Frame::Type::PING, 0, 1, buf) unless frame.flags.ack?

      when Frame::Type::GOAWAY
        _, last_stream_id = read_stream_id
        error_code = Error::Code.from_value(io.read_bytes(UInt32, IO::ByteFormat::BigEndian))
        io.read_fully(buf = Slice(UInt8).new(length - 8))
        error_message = String.new(buf)

        close(notify: false)

        unless error_code == Error::Code::NO_ERROR
          raise ClientError.new(error_code, last_stream_id, error_message)
        end

      #when Frame::Type::WINDOW_UPDATE
      #  raise Error.frame_size_error unless length == WINDOW_UPDATE_FRAME_SIZE
      #  ...

      #when Frame::Type::CONTINUATION
      #  TODO: continue to decode request headers
      #  ...

      else
        io.skip(length)
      end

      puts "<= #{ frame.inspect }"
      frame
    end

    def write_settings
      write HTTP2::Frame.new(HTTP2::Frame::Type::SETTINGS, 0, 0, local_settings.to_payload)
    end

    def write(frame : Frame)
      puts "=> #{ frame.inspect }"

      length = frame.payload?.try(&.size.to_u32) || 0_u32
      io.write_bytes((length << 8) | frame.type.to_u8, IO::ByteFormat::BigEndian)
      io.write_byte(frame.flags.to_u8)
      io.write_bytes(frame.stream_id.to_u32, IO::ByteFormat::BigEndian)

      if payload = frame.payload?
        io.write(payload) if payload.size > 0
      end
    end

    def close(error = nil, notify = true)
      return if closed?
      @closed = true

      unless io.closed?
        if notify
          if error
            payload = MemoryIO.new(8 + error.message.bytesize)
            payload.write_bytes(last_stream_id.to_u32, IO::ByteFormat::BigEndian)
            payload.write_bytes(error.code.to_u32, IO::ByteFormat::BigEndian)
            payload << error.message
          else
            payload = MemoryIO.new(8)
            payload.write_bytes(last_stream_id.to_u32, IO::ByteFormat::BigEndian)
            payload.write_bytes(Error::Code::NO_ERROR.to_u32, IO::ByteFormat::BigEndian)
          end
          write Frame.new(Frame::Type::GOAWAY, 0, 0, payload.to_slice)
        end
        io.close
      end
    end

    def closed?
      @closed
    end

    private def read_byte
      io.read_byte.not_nil!
    end

    private def read_frame_headers
      buf = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      length, type = buf >> 8, buf & 0xff
      flags = read_byte
      r, stream_id = read_stream_id

      unless frame_type = Frame::Type.from_value?(type)
        puts "UNSUPPORTED FRAME 0x#{type.to_s(16)}"
      end

      {length, frame_type, flags, r, stream_id}
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
