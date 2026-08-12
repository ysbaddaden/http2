require "./stream"

module HTTP2
  # Maximum number of closed stream IDs to retain for late WINDOW_UPDATE/RST_STREAM
  # frame handling (RFC 7540). Prevents unbounded memory growth on long-lived connections.
  MAX_CLOSED_STREAM_IDS = 10_000

  class Streams
    # :nodoc:
    protected def initialize(@connection : Connection, type : Connection::Type)
      @streams = {} of Int32 => Stream
      @closed_stream_ids = [] of Int32
      @mutex = Mutex.new  # OPTIMIZE: use Sync::RWLock instead
      @highest_remote_id = 0

      if type.server?
        @id_counter = 0
      else
        @id_counter = -1
      end
    end

    # Removes a closed stream from the active map. Retains its ID so that late
    # WINDOW_UPDATE / RST_STREAM frames (permitted by RFC 7540) can be
    # identified and skipped without re-creating the stream entry.
    # Bounded to MAX_CLOSED_STREAM_IDS to prevent unbounded memory growth.
    protected def remove(id : Int32) : Nil
      return if id == 0
      @mutex.synchronize do
        @streams.delete(id)
        unless @closed_stream_ids.includes?(id)
          @closed_stream_ids << id
          prune_closed_stream_ids if @closed_stream_ids.size > MAX_CLOSED_STREAM_IDS
        end
      end
    end

    private def prune_closed_stream_ids : Nil
      excess = @closed_stream_ids.size - MAX_CLOSED_STREAM_IDS
      @closed_stream_ids = @closed_stream_ids[excess..] if excess > 0
    end

    # Returns true if the stream was closed and removed from the active map.
    protected def recently_closed?(id : Int32) : Bool
      @mutex.synchronize { @closed_stream_ids.includes?(id) }
    end

    # Releases all stream and closed-ID references. Called when the connection closes.
    protected def clear : Nil
      @mutex.synchronize do
        @streams.clear
        @closed_stream_ids.clear
      end
    end

    # Finds an existing stream, silently creating it if it doesn't exist yet.
    #
    # Takes care to increment `highest_remote_id` counter for an incoming
    # stream, unless `consume` is set to false, for example a PRIORITY frame
    # forward declares a stream priority/dependency but doesn't consume the
    # stream identifiers, so they are still valid.
    def find(id : Int32, consume : Bool = true) : Stream
      @mutex.synchronize do
        @streams[id] ||= begin
          if max = @connection.local_settings.max_concurrent_streams
            if unsafe_active_count(1) >= max
              raise Error.refused_stream("MAXIMUM capacity reached")
            end
          end
          if id > @highest_remote_id && consume
            @highest_remote_id = id
          end
          Stream.new(@connection, id)
        end
      end
    end

    protected def each(&)
      @mutex.synchronize do
        @streams.each { |_, stream| yield stream }
      end
    end

    # Returns true if the incoming stream id is valid for the current connection.
    protected def valid?(id : Int32)
      id == 0 || (                                 # stream #0 is always valid
        (id % 2) == 1 && (                         # incoming streams are odd-numbered
          @mutex.synchronize { @streams[id]? } ||  # streams already exists
          id >= @highest_remote_id                 # stream ids must grow (not shrink)
        )
      )
    end

    # Creates an outgoing stream. For example to handle a client request or a
    # server push.
    def create(state = Stream::State::IDLE) : Stream
      @mutex.synchronize do
        if max = @connection.remote_settings.max_concurrent_streams
          if unsafe_active_count(0) >= max
            raise Error.internal_error("MAXIMUM outgoing stream capacity reached")
          end
        end
        id = @id_counter += 2
        raise Error.internal_error("STREAM #{id} already exists") if @streams[id]?
        @streams[id] = Stream.new(@connection, id, state: state)
      end
    end

    # Counts active ingnoring (type=1) or outgoing (type=0) streams.
    protected def active_count(type) : Int32
      @mutex.synchronize { unsafe_active_count(type) }
    end

    private def unsafe_active_count(type) : Int32
      @streams.reduce(0) do |count, (_, stream)|
        if stream.id == 0 || stream.id % 2 == type && stream.active?
          count + 1
        else
          count
        end
      end
    end

    protected def last_stream_id : Int32
      @mutex.synchronize do
        @streams.reduce(0) { |a, (k, _)| a > k ? a : k }
      end
    end
  end
end
