require "./stream"
require "sync/rw_lock"

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

    # Finds an existing stream, silently creating a new stream if it doesn't
    # exist yet. Closed streams are returned without retaining an entry.
    #
    # Advances `highest_remote_id` for a new incoming stream, unless `consume`
    # is set to false, for example a PRIORITY frame forward declares a stream
    # priority/dependency but doesn't consume the stream identifiers, so they
    # are still valid.
    def find(id : Int32, consume : Bool = true) : Stream
      if @lock.try_lock_read?
        stream = @streams[id]?
        @lock.unlock_read
        return stream if stream
      end

      @lock.write do
        if stream = @streams[id]?
          return stream
        end

        # closed identifiers must not become idle streams again (RFC 9113, 5.1.1)
        if 0 < id <= (@type.peer.initiates?(id) ? @highest_remote_id : @id_counter)
          return Stream.new(@connection, id, state: Stream::State::CLOSED)
        end

        # enforce the peer-initiated stream limit
        if @type.peer.initiates?(id)
          if max = @connection.local_settings.max_concurrent_streams
            if unsafe_active_count(@type.peer) >= max
              raise Error.refused_stream("MAXIMUM peer-initiated stream capacity reached")
            end
          end

          if id > @highest_remote_id && consume
            @highest_remote_id = id
          end
        end

        # create new stream
        @streams[id] = Stream.new(@connection, id)
      end
    end

    protected def each(&) : Nil
      @lock.read do
        @streams.each { |_, stream| yield stream }
      end
    end

    protected def increment_outbound_window_size(increment : Int32) : Nil
      overflowing = nil

      @lock.write do
        @streams.each do |_, stream|
          next if stream.id == 0
          unless stream.try_increment_outbound_window_size(increment)
            (overflowing ||= [] of Stream) << stream
          end
        end
      end

      # close the overflowing streams after releasing the lock to avoid
      # deadlocks; a reentrant write lock is insufficient: there could a
      # concurrent fiber sending an END_STREAM or RST_STREAM frame
      overflowing.try &.each(&.send_rst_stream(Error::Code::FLOW_CONTROL_ERROR))
    end

    protected def delete(stream : Stream) : Nil
      @lock.write do
        @streams.delete(stream.id)
      end
    end

    # Checks stream ownership and allocation. Frame validity for the stream's
    # state is checked separately, including for closed identifiers.
    protected def valid?(stream_id : Int32) : Bool
      # stream #0 is always valid
      return true if stream_id == 0

      # peer owns the stream_id (possibly closed)
      return true if @type.peer.initiates?(stream_id)

      @lock.read do
        # already exists, or locally allocated, possibly removed after closing
        return @streams.has_key?(stream_id) || (@type.initiates?(stream_id) && stream_id <= @id_counter)
      end
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
      @lock.read { @highest_remote_id }
    end

    protected def has_key?(id : Int32)
      @streams.has_key?(id)
    end

    # Number of retained streams, including idle and reserved streams. Informational only.
    def size : Int32
      @streams.size
    end
  end
end
