require "./stream"
require "sync/rw_lock"

module HTTP2
  class Streams
    # The identifiers of forgotten streams we reset are remembered, so the
    # frames the peer sent before it received the RST_STREAM are ignored: for
    # as many streams as may be open at once in both directions, plus this
    # margin, and no more than the maximum (RFC 9113 section 5.1).
    private RESET_IDS_MARGIN  =   1024
    private RESET_IDS_MAXIMUM = 65_536

    # :nodoc:
    protected def initialize(@connection : Connection, @type : Connection::Type)
      @streams = {} of Int32 => Stream
      @lock = Sync::RWLock.new
      @highest_remote_id = 0
      @reset_ids = Deque(Int32).new
      @reset_ids_set = Set(Int32).new
      @goaway = false

      case @type
      in .client?
        @id_counter = -1
      in .server?
        @id_counter = 0
      end
    end

    # Finds an existing stream, silently creating it if it doesn't exist yet.
    #
    # Takes care to increment `highest_remote_id` counter for an incoming
    # stream, unless `consume` is set to false, for example a PRIORITY frame
    # forward declares a stream priority/dependency but doesn't consume the
    # stream identifiers, so they are still valid.
    #
    # Closed streams are forgotten: returns a new stream in the CLOSED state
    # for a stream that was opened then forgotten.
    def find(id : Int32, consume : Bool = true) : Stream
      if @lock.try_lock_read?
        begin
          stream = @streams[id]? || unsafe_forgotten(id)
        ensure
          @lock.unlock_read
        end
        return stream if stream
      end

      @lock.write do
        if stream = @streams[id]? || unsafe_forgotten(id)
          next stream
        end

        if @type.peer.initiates?(id)
          if max = @connection.local_settings.max_concurrent_streams
            if unsafe_active_count(@type.peer) >= max
              raise Error.refused_stream("MAXIMUM peer-initiated stream capacity reached")
            end
          end
        end
        if id > @highest_remote_id && consume
          @highest_remote_id = id
        end
        @streams[id] = Stream.new(@connection, id)
      end
    end

    # A stream identifier at or below the last one opened in its direction
    # that isn't in the table belongs to a closed stream (RFC 9113 section
    # 5.1.1), never an idle one. The stream remembers if we reset it.
    private def unsafe_forgotten(id : Int32) : Stream?
      return if id == 0
      return unless id <= (@type.initiates?(id) ? @id_counter : @highest_remote_id)
      Stream.new(@connection, id, state: Stream::State::CLOSED, reset_sent: @reset_ids_set.includes?(id))
    end

    # Forgets a closed stream, so it can be garbage collected once nothing
    # else references it (e.g. a body that hasn't been read yet).
    protected def remove(stream : Stream) : Nil
      @lock.write do
        @streams.delete(stream.id)

        if stream.reset_sent?
          @reset_ids << stream.id
          @reset_ids_set << stream.id

          limit = reset_ids_limit
          while @reset_ids.size > limit
            @reset_ids_set.delete(@reset_ids.shift)
          end
        end
      end
    end

    private def reset_ids_limit : Int32
      local = @connection.local_settings.max_concurrent_streams || 0_u32
      remote = @connection.remote_settings.max_concurrent_streams || 0_u32
      Math.min(RESET_IDS_MARGIN.to_u64 + local + remote, RESET_IDS_MAXIMUM.to_u64).to_i32
    end

    # Yields each stream. Iterates a copy of the streams, so the block may
    # close (and forget) streams.
    protected def each(&)
      @lock.read { @streams.values }.each { |stream| yield stream }
    end

    # Returns true if the incoming *stream_id* is valid for the current
    # connection.
    protected def valid?(stream_id : Int32, frame_type : Frame::Type)
      return true if stream_id == 0 # stream #0 is always valid

      if @type.initiates?(stream_id)
        # we own the stream_id: we must have opened the stream already
        @lock.read { stream_id <= @id_counter }
      else
        # peer owns the stream_id: stream already exists, or stream id grows
        # (can't shrink), or the stream was closed (and forgotten) but a
        # HEADERS frame can't open a new stream there, unless we reset it:
        # the peer may have sent HEADERS (trailers) before it received the
        # RST_STREAM, that the connection ignores (RFC 9113 section 5.1)
        stream_id >= @highest_remote_id ||
          !frame_type.headers? ||
          @lock.read { @streams.has_key?(stream_id) || @reset_ids_set.includes?(stream_id) }
      end
    end

    # Creates an outgoing stream. For example to handle a client request or a
    # server push.
    def create(state = Stream::State::IDLE) : Stream
      @lock.write do
        raise Error.refused_stream("GOAWAY received") if @goaway
        if max = @connection.remote_settings.max_concurrent_streams
          if unsafe_active_count(@type) >= max
            raise Error.refused_stream("MAXIMUM outgoing stream capacity reached")
          end
        end
        id = @id_counter += 2
        raise Error.internal_error("STREAM #{id} already exists") if @streams[id]?
        @streams[id] = Stream.new(@connection, id, state: state)
      end
    end

    # Refuses to create streams once the peer sent GOAWAY. Returns the streams
    # we opened above *last_stream_id*, that the peer won't process.
    protected def goaway(last_stream_id : Int32) : Array(Stream)
      @lock.write do
        @goaway = true
        @streams.values.select { |stream| @type.initiates?(stream.id) && stream.id > last_stream_id }
      end
    end

    # Counts active streams for the connection type or its peer. For example:
    #
    # ```
    # outgoing = active_count(@type)
    # incoming = active_count(@type.peer)
    # ```
    def active_count(type : Connection::Type) : Int32
      @lock.read do
        unsafe_active_count(type)
      end
    end

    private def unsafe_active_count(type : Connection::Type) : Int32
      @streams.reduce(0) do |count, (_, stream)|
        if type.initiates?(stream.id) && stream.active?
          count + 1
        else
          count
        end
      end
    end

    # The highest identifier of a stream the peer opened, that we may have
    # processed (RFC 9113 section 6.8).
    protected def last_stream_id : Int32
      @lock.read { @highest_remote_id }
    end
  end
end
