require "./stream"

module HTTP2
  class Streams
    # :nodoc:
    protected def initialize(@connection : Connection, @type : Connection::Type)
      @streams = {} of Int32 => Stream
      @lock = Sync::RWLock.new
      @highest_remote_id = 0

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
    def find(id : Int32, consume : Bool = true) : Stream
      if @lock.try_lock_read?
        stream = @streams[id]?
        @lock.unlock_read
        return stream if stream
      end

      @lock.write do
        @streams[id] ||= begin
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
          Stream.new(@connection, id)
        end
      end
    end

    protected def each(&)
      @lock.read do
        @streams.each { |_, stream| yield stream }
      end
    end

    # Returns true if the incoming *stream_id* is valid for the current
    # connection.
    protected def valid?(stream_id : Int32)
      stream_id == 0 || (                                # stream #0 is always valid, or
        @type.peer.initiates?(stream_id) && (            # peer owns the stream_id, and
          @lock.read { @streams[stream_id]? } || # stream already exists, or
          stream_id >= @highest_remote_id                # stream id grows (can't shrink)
        )
      )
    end

    # Creates an outgoing stream. For example to handle a client request or a
    # server push.
    def create(state = Stream::State::IDLE) : Stream
      @lock.write do
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

    # Counts active streams for the connection type or its peer. For example:
    #
    # ```
    # outgoing = active_count(@type)
    # incoming = active_count(@type.peer)
    # ```
    protected def active_count(type : Connection::Type) : Int32
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

    protected def last_stream_id : Int32
      @lock.read do
        @streams.reduce(0) { |a, (k, _)| a > k ? a : k }
      end
    end
  end
end
