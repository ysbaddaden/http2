require "colorize"
require "sync/mutex"
require "./log"
require "./config"
require "./errors"
require "./frame"
require "./hpack"
require "./settings"
require "./streams"

module HTTP2
  DEFAULT_SETTINGS = Settings.new(
    max_concurrent_streams: 100,
    max_header_list_size: 16384,
  )

  class Connection
    enum Type
      CLIENT
      SERVER

      # Returns the remote endpoint type.
      def peer : self
        case self
        in CLIENT
          SERVER
        in SERVER
          CLIENT
        end
      end

      # Returns true if *stream_id* is initiated by this endpoint.
      def initiates?(stream_id : Int32) : Bool
        # RFC 9113 assigns odd stream IDs to client-initiated streams and even
        # stream IDs to server-initiated streams. This compares the stream ID's
        # oddness to whether this endpoint is the client; it does not rely on
        # enum numeric values.
        stream_id > 0 && stream_id.odd? == client?
      end
    end

    # ACK frame flag == END_STREAM...
    private ACK = Frame::Flags::END_STREAM

    # Local settings. You may tune local settings prior to establishing the
    # connection (prior to `#write_settings`) or later on, in which case you
    # must call `#send_settings` to report changes to the remote peer.
    getter local_settings : Settings

    # Settings of remote peer. Updated whenever a SETTINGS frame is received.
    getter remote_settings : Settings

    protected getter hpack_encoder : HPACK::Encoder
    protected getter hpack_decoder : HPACK::Decoder
    private getter io : IO
    getter streams : Streams

    @data_buffer : Bytes? = nil

    # The SETTINGS_ENABLE_PUSH value of each SETTINGS frame we sent that the
    # peer didn't acknowledge yet, oldest first, and the value it applied
    # last: the peer acknowledges SETTINGS frames in order, once it applied
    # them (RFC 9113 section 6.5.3).
    @unacknowledged_enable_push = Deque(Bool).new
    @acknowledged_enable_push = DEFAULT_ENABLE_PUSH

    # The size of the connection flow-control window we keep for the peer to
    # send DATA (RFC 9113 section 6.9): once less than half of it is
    # available, the window grows by that size. Defaults to `nil`: the local
    # initial window size for every active stream. Set it before
    # `#write_settings` for a window larger than 65535 bytes from the start.
    getter local_window_size : Int32?

    def local_window_size=(size : Int) : Nil
      raise Error.flow_control_error unless MINIMUM_WINDOW_SIZE <= size <= MAXIMUM_WINDOW_SIZE
      @local_window_size = size.to_i32
    end

    def initialize(@io : IO, @type : Type)
      @local_settings = DEFAULT_SETTINGS.dup
      # the client doesn't handle server push (RFC 9113 section 8.4)
      @local_settings.enable_push = false if @type.client?
      @remote_settings = Settings.new

      @mutex = uninitialized ReferenceStorage(Sync::Mutex)
      Sync::Mutex.unsafe_construct(pointerof(@mutex), Sync::Type::Unchecked)

      @closed = false
      @write_failed = false

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

      # Holds @streams associated to the connection. Can be used to find an
      # existing stream or create a new stream —odd numbered for client requests,
      # even numbered for server pushed requests.
      @streams = uninitialized Streams
      @streams = Streams.new(self, @type)
    end

    # Reads the expected `HTTP2::CLIENT_PREFACE` for a server context.
    #
    # You may set *truncated* to true if the request line was already read, for
    # example when trying to figure out whether the request was a HTTP/1 or
    # HTTP/2 direct request, where `"PRI * HTTP/2.0\r\n"` was already consumed.
    def read_client_preface(truncated = false) : Nil
      raise "can't read HTTP/2 client preface on a client connection" unless @type.server?
      if truncated
        buf1 = uninitialized UInt8[8]
        buffer = buf1.to_slice
        preface = CLIENT_PREFACE[-8, 8]
      else
        buf2 = uninitialized UInt8[24]
        buffer = buf2.to_slice
        preface = CLIENT_PREFACE
      end
      io.read_fully(buffer)
      unless String.new(buffer) == preface
        raise Error.protocol_error("PREFACE expected")
      end
    end

    # Writes the `HTTP2::CLIENT_PREFACE` to initialize an HTTP/2 client
    # connection.
    def write_client_preface : Nil
      raise "can't write HTTP/2 client preface on a server connection" unless @type.client?
      io << CLIENT_PREFACE
    end

    # Call in the main loop to receive individual frames.
    #
    # Most frames are already being taken care of, so only HEADERS, DATA or
    # PUSH_PROMISE frames should really be interesting. Other frames can be
    # ignored safely.
    #
    # Unknown frame types are reported with a raw `Frame#payload`, so a client
    # or server may handle them (e.g. custom extensions). They can be safely
    # ignored.
    #
    # Returns `nil` when the frame was ignored, for example DATA received on a
    # stream after we reset it or an interim (1xx) response on a client, or
    # when it made the request or response malformed and the stream was reset,
    # or a PUSH_PROMISE whose promised stream we refused.
    #
    # A PUSH_PROMISE frame is reported on the stream it was sent on; the
    # promised stream, with the promised request headers, is
    # `Frame#promised_stream`.
    def receive : Frame?
      frame = read_frame_header
      stream = frame.stream

      if stream.reset_sent? && stream.state.closed?
        case frame.type
        when Frame::Type::DATA
          ignore_data_frame(frame)
          return
        when Frame::Type::HEADERS
          ignore_headers_frame(frame)
          return
        end
      end

      # a PUSH_PROMISE frame reserves the promised stream, the stream it's
      # sent on stays as it is (RFC 9113 section 6.6)
      stream.receiving(frame) unless frame.type == Frame::Type::PUSH_PROMISE

      case frame.type
      when Frame::Type::DATA
        raise Error.protocol_error if stream.id == 0
        return unless read_data_frame(frame)

      when Frame::Type::HEADERS
        raise Error.protocol_error if stream.id == 0
        return unless read_headers_frame(frame)

      when Frame::Type::PUSH_PROMISE
        raise Error.protocol_error if stream.id == 0
        return unless read_push_promise_frame(frame)

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
        raise Error.protocol_error unless stream.id == 0
        read_goaway_frame(frame)

      when Frame::Type::WINDOW_UPDATE
        read_window_update_frame(frame)

      when Frame::Type::CONTINUATION
        raise Error.protocol_error("UNEXPECTED CONTINUATION frame")

      else
        read_unsupported_frame(frame)
      end

      frame
    end

    # Reads padding information and yields the actual frame size without the
    # padding size. Eventually skips the padding.
    private def read_padded(frame, &)
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
      size, type = (buf >> 8).to_i, buf & 0xff
      flags = Frame::Flags.new(read_byte)
      _, stream_id = read_stream_id

      # the peer must not send a frame larger than our SETTINGS_MAX_FRAME_SIZE
      # (RFC 9113 section 4.2)
      if size > local_settings.max_frame_size
        raise Error.frame_size_error
      end

      frame_type = Frame::Type.new(type.to_i)
      unless frame_type.priority? || streams.valid?(stream_id, frame_type)
        raise Error.protocol_error("INVALID stream_id ##{stream_id}")
      end

      stream = streams.find(stream_id, consume: !frame_type.priority?)
      frame = Frame.new(frame_type, stream, flags, size: size)

      Log.trace { "recv #{frame.debug(color: :light_cyan)}" }

      frame
    end

    # The whole DATA frame counts against the flow-control windows, the Pad
    # Length field and the padding included (RFC 9113 section 6.9.1). The
    # body gives the stream window back as it's read, but the padding never
    # reaches the body: it goes back to the stream at once, unless the
    # stream ended, so it can't exhaust the stream window.
    private def read_data_frame(frame) : Bool
      stream = frame.stream
      valid = true

      consume_inbound_window_size(frame.size)

      read_padded(frame) do |size|
        # skipped if another fiber closed the body meanwhile
        next unless stream.data.copy_from(io, size, data_buffer)

        if frame.flags.end_stream?
          valid = close_body(stream)
        elsif (padding = frame.size - size) > 0
          stream.send_window_update_frame(padding)
        end
      end

      valid
    end

    private def read_headers_frame(frame) : Bool
      stream = frame.stream
      valid = true

      read_padded(frame) do |size|
        if frame.flags.priority?
          exclusive, dep_stream_id = read_stream_id
          raise Error.protocol_error("INVALID stream dependency") if stream.id == dep_stream_id
          weight = read_byte.to_i32 + 1
          stream.priority = Priority.new(exclusive == 1, dep_stream_id, weight)
          Log.trace { "  #{stream.priority.debug}" }
          size -= 5
        end

        # only a trailer section may follow the request or the final
        # response, with or without a body (RFC 9113 section 8.1); a client
        # keeps the headers of the final response only, but those of a
        # promised stream hold the promised request until its response
        trailer = stream.data? ||
                  (@type.client? ? stream.headers.has_key?(":status") : !stream.headers.empty?)

        buffer = read_headers_payload(frame, size)
        interim = false
        malformed = false

        # a malformed message is a stream error (RFC 9113 section 8.1.1)
        if trailer
          trailers = HTTP::Headers.new
          # a trailer section ends the stream and has no pseudo-header
          # fields (RFC 9113 section 8.1)
          malformed = !decode_header_block(buffer, trailers) || !frame.flags.end_stream? ||
                      !valid_fields?(trailers, NO_PSEUDO_HEADERS)
          stream.trailers = trailers unless malformed
        elsif @type.server?
          malformed = !decode_header_block(buffer, stream.headers) || !valid_request_headers?(stream.headers)
        else
          # interim (1xx) responses may precede the response, each in its
          # own header block (RFC 9113 section 8.1)
          headers = HTTP::Headers.new
          malformed = !decode_header_block(buffer, headers) || !valid_fields?(headers, RESPONSE_PSEUDO_HEADERS)
          unless malformed
            interim = headers[":status"]?.try(&.starts_with?('1')) || false
            stream.headers.merge!(headers) unless interim
          end
        end

        if malformed || (interim && frame.flags.end_stream?)
          # an interim response that ends the stream is malformed too (RFC
          # 9113 section 8.1.1)
          stream.send_rst_stream(Error::Code::PROTOCOL_ERROR)
          stream.abort
          valid = false
        elsif interim
          # skips the interim response
          valid = false
        elsif frame.flags.end_stream?
          # https://tools.ietf.org/html/rfc7540#section-8.1
          # https://tools.ietf.org/html/rfc7230#section-4.1.2
          valid = close_body(stream)
        end
      end

      valid
    end

    # Closes the body once the peer ended the stream. A body whose size
    # doesn't match the content-length header, or an invalid content-length,
    # is malformed: resets the stream (a stream error, RFC 9113 section
    # 8.1.1) and returns false.
    private def close_body(stream) : Bool
      if content_length = stream.headers["content-length"]?
        # a response to HEAD, a 204 or a 304 has no content but may have a
        # content-length (RFC 9113 section 8.1.1, RFC 9110 section 6.4.1)
        bodiless_response = @type.client? && stream.data.size == 0 &&
                            (stream.head_request? || {"204", "304"}.includes?(stream.headers[":status"]?))

        length = parse_content_length(content_length)
        unless length && (length == stream.data.size || bodiless_response)
          stream.send_rst_stream(Error::Code::PROTOCOL_ERROR)
          stream.abort
          return false
        end
      end

      stream.data.close_write
      true
    end

    # Parses a content-length value: digits only (RFC 9110 section 8.6).
    # Returns nil if the value is invalid or too large.
    private def parse_content_length(value : String) : UInt64?
      value.to_u64?(whitespace: false) if value.each_char.all?(&.ascii_number?)
    end

    # The buffer DATA is read into before it's copied to a stream's body.
    # Only the fiber that receives frames uses it.
    private def data_buffer : Bytes
      @data_buffer ||= Bytes.new(DEFAULT_MAX_FRAME_SIZE)
    end

    # Ignores a DATA frame received on a stream we reset, that the peer sent
    # before it received the RST_STREAM. It still counts against the
    # connection window, padding included, and its pad length must fit in
    # the frame (RFC 9113 sections 5.1, 6.1 and 6.9).
    private def ignore_data_frame(frame) : Nil
      consume_inbound_window_size(frame.size)
      read_padded(frame) { |size| io.skip(size) }
    end

    # Ignores a HEADERS frame received on a stream we reset, that the peer sent
    # before it received the RST_STREAM. The header block must still be
    # decoded to keep the HPACK decoder in sync (RFC 9113 sections 4.3 and 5.1).
    private def ignore_headers_frame(frame) : Nil
      read_padded(frame) do |size|
        if frame.flags.priority?
          io.skip(5)
          size -= 5
        end
        buffer = read_headers_payload(frame, size)
        decode_header_block(buffer, HTTP::Headers.new)
      end
    end

    private NO_PSEUDO_HEADERS = [] of String

    # Returns false if the request is malformed: invalid fields, or a
    # missing or repeated `:method`, `:scheme` or `:path` (RFC 9113 section
    # 8.3.1).
    private def valid_request_headers?(headers : HTTP::Headers) : Bool
      return false unless valid_fields?(headers, REQUEST_PSEUDO_HEADERS)
      return false unless headers.get?(":method").try(&.size) == 1

      unless headers[":method"] == "CONNECT"
        return false unless headers.get?(":scheme").try(&.size) == 1
        paths = headers.get?(":path")
        return false unless paths && paths.size == 1 && !paths.first.empty?
      end

      true
    end

    # Returns false if a field makes the message malformed (RFC 9113 section
    # 8.2): an uppercase name, a pseudo-header field that isn't one of
    # *pseudo* or that follows a regular field, or a connection-specific
    # field.
    private def valid_fields?(headers : HTTP::Headers, pseudo : Array(String)) : Bool
      regular = false

      headers.each do |name, values|
        # pseudo-header fields come before the regular fields
        regular ||= !name.starts_with?(':')
        return false if name.starts_with?(':') && (regular || !pseudo.includes?(name))

        # field names are lowercase (RFC 9113 section 8.2.1)
        return false if name.each_char.any?(&.ascii_uppercase?)

        return false if CONNECTION_SPECIFIC_FIELDS.includes?(name)
        return false if name == "te" && values != ["trailers"]
      end

      true
    end

    # OPTIMIZE: consider CircularBuffer and decompressing HPACK headers
    # in-parallel instead of reallocating pointers and eventually
    # decompressing everything
    private def read_headers_payload(frame, size)
      stream = frame.stream
      validate_header_block_size(size)

      pointer = GC.malloc_atomic(size).as(UInt8*)
      io.read_fully(pointer.to_slice(size))

      loop do
        break if frame.flags.end_headers?

        frame = read_frame_header
        unless frame.type == Frame::Type::CONTINUATION
          raise Error.protocol_error("EXPECTED continuation frame")
        end
        unless frame.stream == stream
          raise Error.protocol_error("EXPECTED continuation frame for stream ##{stream.id} not ##{frame.stream.id}")
        end

        validate_header_block_size(size + frame.size)
        pointer = pointer.realloc(size + frame.size)
        io.read_fully((pointer + size).to_slice(frame.size))

        size += frame.size
      end

      pointer.to_slice(size)
    end

    # Decodes a header block into *headers*. The decoded list can't be larger
    # than the SETTINGS_MAX_HEADER_LIST_SIZE we announced, indexed fields
    # included: a small block may reference large entries of the dynamic
    # table many times (RFC 9113 sections 6.5.2 and 10.5.1). That is a
    # connection error, as for a block too large to buffer.
    #
    # Returns false if a field has an invalid name or value: the message is
    # malformed (RFC 9113 section 8.2.1).
    private def decode_header_block(buffer : Bytes, headers : HTTP::Headers) : Bool
      hpack_decoder.decode(buffer, headers, local_settings.max_header_list_size)
      true
    rescue ex : HPACK::InvalidFieldError
      false
    rescue ex : HPACK::ListSizeError
      raise Error.protocol_error("HEADER list size exceeds limit")
    rescue ex : HPACK::Error
      Log.trace { "HPACK::Error: #{ex.message}" }
      raise Error.compression_error
    end

    # Refuses a header block larger than the SETTINGS_MAX_HEADER_LIST_SIZE we
    # announced before reading it, so a peer can't make us buffer an
    # unbounded block: an encoded field is never smaller than the octets its
    # name and value add to the list, so a block that large always encodes a
    # list that is too large (RFC 9113 sections 6.5.2 and 10.5.1).
    private def validate_header_block_size(size) : Nil
      if (max_size = local_settings.max_header_list_size) && size > max_size
        raise Error.protocol_error("HEADER list size exceeds limit")
      end
    end

    # Reserves the promised stream and decodes the promised request into its
    # headers (RFC 9113 sections 6.6 and 8.4). Only a server may push, on a
    # stream that is open or half-closed (local), unless we disabled push and
    # it acknowledged that (RFC 9113 section 6.5.2).
    #
    # The server may have sent the frame before it received the RST_STREAM we
    # sent on the stream: the promised stream is still reserved and the
    # header block decoded, to keep the HPACK decoder in sync, then we refuse
    # the promised stream (RFC 9113 section 5.1). We refuse it as well while
    # the server didn't acknowledge that we disabled push. Returns false
    # then.
    private def read_push_promise_frame(frame) : Bool
      stream = frame.stream

      raise Error.protocol_error("UNEXPECTED PUSH_PROMISE frame") if @type.server?
      raise Error.protocol_error("PUSH disabled") if push_disabled?

      reset = stream.reset_sent? && stream.state.closed?
      unless reset || stream.state.open? || stream.state.half_closed_local?
        raise Error.protocol_error("STREAM #{stream.id} is #{stream.state}")
      end

      malformed = false

      read_padded(frame) do |size|
        raise Error.frame_size_error if size < 4
        _, promised_stream_id = read_stream_id

        # the promised stream must be a new stream of the server (RFC 9113
        # section 5.1.1)
        promised = streams.find(promised_stream_id) if @type.peer.initiates?(promised_stream_id)
        unless promised && promised.state.idle?
          raise Error.protocol_error("INVALID promised stream_id ##{promised_stream_id}")
        end
        promised.receiving(frame)
        frame.promised_stream = promised

        buffer = read_headers_payload(frame, size - 4)
        malformed = !decode_header_block(buffer, promised.headers) || !valid_request_headers?(promised.headers)
      end

      if malformed
        # a malformed promised request is a stream error on the promised
        # stream (RFC 9113 section 8.4.1)
        frame.promised_stream.send_rst_stream(Error::Code::PROTOCOL_ERROR)
        return false
      end

      # another fiber may have reset the stream meanwhile
      if stream.state.closed? || !local_settings.enable_push
        frame.promised_stream.send_rst_stream(Error::Code::REFUSED_STREAM)
        return false
      end

      true
    end

    # Returns true if we disabled push, the peer acknowledged it, and we
    # didn't enable push again since.
    private def push_disabled? : Bool
      @mutex.to_reference.synchronize do
        !@acknowledged_enable_push && !@unacknowledged_enable_push.includes?(true)
      end
    end

    private def read_priority_frame(frame)
      stream = frame.stream
      raise Error.frame_size_error unless frame.size == PRIORITY_FRAME_SIZE

      exclusive, dep_stream_id = read_stream_id
      raise Error.protocol_error("INVALID stream dependency") if stream.id == dep_stream_id

      weight = 1 + read_byte
      stream.priority = Priority.new(exclusive == 1, dep_stream_id, weight)

      Log.trace { "  #{stream.priority.debug}" }
    end

    private def read_rst_stream_frame(frame)
      raise Error.frame_size_error unless frame.size == RST_STREAM_FRAME_SIZE
      error_code = Error::Code.new(io.read_bytes(UInt32, IO::ByteFormat::BigEndian))
      frame.error = error_code
      Log.trace { "  code=#{error_code.to_s}" }
      frame.stream.reset_received(error_code)
    end

    private def read_settings_frame(frame)
      raise Error.frame_size_error unless frame.size % 6 == 0

      if frame.flags.ack?
        @mutex.to_reference.synchronize do
          enable_push = @unacknowledged_enable_push.shift?
          @acknowledged_enable_push = enable_push unless enable_push.nil?
        end
        return
      end

      remote_settings.parse(io, frame.size // 6) do |id, value|
        Log.trace { "  #{id}=#{value}" }

        case id
        when Settings::Identifier::HEADER_TABLE_SIZE
          hpack_decoder.max_table_size = value.to_i32

        when Settings::Identifier::INITIAL_WINDOW_SIZE
          difference = value.to_i32 - remote_settings.initial_window_size

          # adjust windows size for all control-flow streams (doesn't affect
          # the connection window size):
          unless difference == 0
            streams.each do |stream|
              next if stream.id == 0
              stream.increment_outbound_window_size(difference)
            end
          end
        end
      end

      # ACK reception of remote SETTINGS:
      send Frame.new(Frame::Type::SETTINGS, frame.stream, ACK)
    end

    private def read_ping_frame(frame)
      raise Error.frame_size_error unless frame.size == PING_FRAME_SIZE

      buffer = Bytes.new(8) # PING_FRAME_SIZE
      io.read_fully(buffer)

      if frame.flags.ack?
        # TODO: validate buffer == previously sent PING value
      else
        send Frame.new(Frame::Type::PING, frame.stream, ACK, buffer)
      end
    end

    private def read_goaway_frame(frame)
      # last_stream_id and the error code, then optional debug data
      raise Error.frame_size_error unless frame.size >= 8
      _, last_stream_id = read_stream_id
      error_code = Error::Code.new(io.read_bytes(UInt32, IO::ByteFormat::BigEndian))

      buffer = Bytes.new(frame.size - 8)
      io.read_fully(buffer)
      Log.trace { "  last_stream_id=#{last_stream_id} code=#{error_code.to_s} debug=#{String.new(buffer).inspect}" }

      frame.last_stream_id = last_stream_id
      frame.error = error_code

      # the peer won't accept new streams nor process the streams we opened
      # above last_stream_id (they may be retried), whatever the error code,
      # but the other streams may still complete (RFC 9113 section 6.8)
      streams.goaway(last_stream_id).each(&.abort)
    end

    private def read_window_update_frame(frame)
      stream = frame.stream

      raise Error.frame_size_error unless frame.size == WINDOW_UPDATE_FRAME_SIZE
      buf = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
      # reserved = buf.bit(31)
      window_size_increment = (buf & 0x7fffffff_u32).to_i32
      raise Error.protocol_error unless MINIMUM_WINDOW_SIZE <= window_size_increment <= MAXIMUM_WINDOW_SIZE

      Log.trace { "  WINDOW_SIZE_INCREMENT=#{window_size_increment}" }

      if stream.id == 0
        increment_outbound_window_size(window_size_increment)
      elsif !stream.state.closed?
        # nothing may be sent on a closed stream: the increment is ignored,
        # and can't be an error (RFC 9113 sections 5.1 and 6.9)
        stream.increment_outbound_window_size(window_size_increment)
      end
    end

    private def read_unsupported_frame(frame)
      frame.payload = Bytes.new(frame.size)
      io.read(frame.payload)
    end

    # Sends a frame to the connected peer.
    #
    # One may also send an Array(Frame) for the case when some frames must be
    # sliced (in order to respect max frame size) but must be sent as a single
    # block (multiplexing would cause a protocol error).
    #
    # So far this only applies to HEADERS (and PUSH_PROMISE) and CONTINUATION
    # frames, otherwise HPACK compression synchronisation could end up corrupted
    # if another HEADERS frame for another stream was sent in between.
    def send(frame : Frame | Array(Frame)) : Nil
      synchronize { write(frame) }
    end

    # Opens a stream and sends its HEADERS frame, possibly followed by
    # CONTINUATION frames, at once: no other stream can be opened in between,
    # so the stream identifiers go on the wire in increasing order (RFC 9113
    # section 5.1.1).
    #
    # Raises `Error` with REFUSED_STREAM if the peer's maximum of concurrent
    # streams is reached or the peer sent GOAWAY.
    def open_stream(headers : HTTP::Headers, flags : Frame::Flags = Frame::Flags::None) : Stream
      synchronize do
        streams.create.tap { |stream| write(stream.headers_frames(headers, flags)) }
      end
    end

    # Encodes and sends a header block on *stream*, so the header blocks are
    # sent in the order they're encoded (RFC 9113 section 4.3).
    protected def send_headers(stream : Stream, headers : HTTP::Headers, flags : Frame::Flags) : Nil
      synchronize { write(stream.headers_frames(headers, flags)) }
    end

    # Reserves a stream and sends the PUSH_PROMISE frame that promises it on
    # *stream*, possibly followed by CONTINUATION frames, at once: the
    # promised stream identifiers go on the wire in increasing order, and the
    # header blocks in the order they're encoded (RFC 9113 sections 4.3 and
    # 5.1.1). *stream* must be open or half-closed (remote) (RFC 9113 section
    # 6.6).
    protected def send_push_promise(stream : Stream, headers : HTTP::Headers, flags : Frame::Flags) : Stream
      synchronize do
        unless stream.state.open? || stream.state.half_closed_remote?
          raise Error.internal_error("STREAM #{stream.id} is #{stream.state}")
        end
        streams.create(state: Stream::State::RESERVED_LOCAL).tap do |promised|
          write(stream.push_promise_frames(promised, headers, flags))
        end
      end
    end

    private def synchronize(&)
      @mutex.to_reference.synchronize { yield }
    rescue ex
      # a partial frame may be on the wire: the connection is unusable
      close(notify: false) if @write_failed
      raise ex
    end

    # Immediately writes local settings to the connection.
    #
    # This is UNSAFE and MUST only be called for sending the initial SETTINGS
    # frame. Sending changes to `#local_settings` once the connection
    # established MUST use `#send_settings` instead!
    def write_settings : Nil
      @unacknowledged_enable_push << local_settings.enable_push
      write Frame.new(HTTP2::Frame::Type::SETTINGS, streams.find(0), payload: local_settings.to_payload)

      # the connection window starts at 65535 bytes whatever the settings
      # (RFC 9113 section 6.9.2): grows it right away
      increment = connection_window_size - @inbound_window_size
      if increment > 0
        @inbound_window_size += increment
        streams.find(0).send_window_update_frame(increment)
      end
    end

    # Sends a SETTINGS frame for the current `#local_settings` values.
    def send_settings : Nil
      synchronize do
        @unacknowledged_enable_push << local_settings.enable_push
        write Frame.new(HTTP2::Frame::Type::SETTINGS, streams.find(0), payload: local_settings.to_payload)
      end
    end

    private def write(frames : Array(Frame)) : Nil
      frames.each_with_index { |frame, i| write(frame, flush: i == frames.size - 1) }
    end

    private def write(frame : Frame, flush = true) : Nil
      raise IO::Error.new("Closed stream") if @write_failed

      size = frame.payload?.try(&.size.to_u32) || 0_u32
      stream = frame.stream

      Log.trace { "send #{frame.debug(color: :light_magenta)}" }
      stream.sending(frame) unless frame.type == Frame::Type::PUSH_PROMISE

      begin
        io.write_bytes((size << 8) | frame.type.to_u8, IO::ByteFormat::BigEndian)
        io.write_byte(frame.flags.to_u8)
        io.write_bytes(stream.id.to_u32, IO::ByteFormat::BigEndian)

        if (payload = frame.payload?) && (payload.size > 0)
          io.write(payload)
        end

        if flush
          io.flush
        end
      rescue ex
        # we can't tell how much of the frame was written: nothing may be
        # written anymore
        @write_failed = true
        raise ex
      end
    end

    # Keeps the inbound window size (when receiving DATA frames). If the
    # available size shrinks below half the connection window size, sends a
    # WINDOW_UPDATE frame to increment it by the connection window size,
    # respecting `MAXIMUM_WINDOW_SIZE`.
    private def consume_inbound_window_size(size)
      @inbound_window_size -= size
      window_size = connection_window_size

      if @inbound_window_size < window_size // 2
        increment = Math.min(window_size, MAXIMUM_WINDOW_SIZE.to_i64 - @inbound_window_size).to_i32
        @inbound_window_size += increment
        streams.find(0).send_window_update_frame(increment)
      end
    end

    # The connection window size: `#local_window_size`, or the local initial
    # window size for every active stream (at least one), no more than
    # `MAXIMUM_WINDOW_SIZE`.
    private def connection_window_size : Int32
      if size = @local_window_size
        return size
      end
      active_count = streams.active_count(@type) + streams.active_count(@type.peer)
      Math.min(local_settings.initial_window_size.to_i64 * Math.max(active_count, 1), MAXIMUM_WINDOW_SIZE).to_i32
    end

    protected def outbound_window_size
      @outbound_window_size.get(:relaxed)
    end

    # Tries to consume *size* bytes from the connection outbound window size,
    # but may return a lower value, or even 0.
    protected def consume_outbound_window_size(size)
      window_size = outbound_window_size

      while true
        return 0 if window_size == 0

        available = Math.min(size, window_size)

        window_size, success = @outbound_window_size.compare_and_set(window_size, window_size - available, :relaxed, :relaxed)
        return available if success
      end
    end

    # Gives back *size* bytes a stream consumed from the connection outbound
    # window size but didn't send.
    protected def restore_outbound_window_size(size : Int32) : Nil
      @outbound_window_size.add(size, :relaxed)
      streams.each(&.resume_senders)
    end

    # Increments the connection outbound window size.
    private def increment_outbound_window_size(increment) : Nil
      if outbound_window_size.to_i64 + increment > MAXIMUM_WINDOW_SIZE
        raise Error.flow_control_error
      end
      @outbound_window_size.add(increment, :relaxed)
      streams.each(&.resume_senders)
    end

    # Terminates the HTTP/2 connection.
    #
    # This will send a GOAWAY frame if *notify* is true, reporting an
    # `Error::Code` optional message if present to report an error, or
    # `Error::Code::NO_ERROR` to terminate the connection cleanly.
    #
    # Closes every stream: pending and further reads of a body that wasn't
    # received in full raise, as do pending and further sends. Call it once
    # `#receive` raised, so the streams don't wait for frames that will never
    # come.
    #
    # NOTE: doesn't close the IO, only the HTTP/2 connection.
    def close(error : Error? = nil, notify : Bool = true)
      @mutex.to_reference.synchronize do
        unless closed?
          @closed = true

          unless io.closed? || !notify
            if error
              message, code = error.message || "", error.code
            else
              message, code = "", Error::Code::NO_ERROR
            end

            payload = IO::Memory.new(8 + message.bytesize)
            payload.write_bytes(streams.last_stream_id.to_u32, IO::ByteFormat::BigEndian)
            payload.write_bytes(code.to_u32, IO::ByteFormat::BigEndian)
            payload << message

            write Frame.new(Frame::Type::GOAWAY, streams.find(0), payload: payload.to_slice)
          end
        end
      end
    rescue ex
      # the connection is closing: an error writing the GOAWAY frame, an
      # IO::Error or not (e.g. OpenSSL::SSL::Error), mustn't stop it
      Log.trace { "GOAWAY not sent: #{ex.message}" }
    ensure
      streams.each { |stream| stream.abort unless stream.id == 0 }
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
