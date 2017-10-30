require "./stream"

module HTTP2
  class Streams
    # :nodoc:
    protected def initialize(@connection : Connection, type : Connection::Type)
      @streams = {} of Int32 => Stream
      @mutex = Mutex.new
      @highest_remote_id = 0

      if type.server?
        @id_counter = 0
      else
        @id_counter = -1
      end
    end

    # Finds an existing stream, silently creating it if it doesn't exist yet.
    #
    # Takes care to increment `highest_remote_id` counter for an incoming
    # stream, unless `consume` is set to false, for example a PRIORITY frame
    # forward declares a stream priority/dependency but doesn't consume the
    # stream identifiers, so they are still valid.
    def find(id : Int32, consume : Bool = true)
      @mutex.synchronize do
        @streams[id] ||= begin
          if max = @connection.local_settings.max_concurrent_streams
            if active_count(1) >= max
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

    protected def each
      @mutex.synchronize do
        @streams.each { |_, stream| yield stream }
      end
    end

    # Returns true if the incoming stream id is valid for the current connection.
    protected def valid?(id : Int32)
      id == 0 || (                   # stream #0 is always valid
        (id % 2) == 1 && (           # incoming streams are odd-numbered
          @streams[id]? ||           # streams already exists
          id >= @highest_remote_id   # stream ids must grow (not shrink)
        )
      )
    end

    # Creates an outgoing stream. For example to handle a client request or a
    # server push.
    def create(state = Stream::State::IDLE)
      @mutex.synchronize do
        if max = @connection.remote_settings.max_concurrent_streams
          if active_count(0) >= max
            raise Error.internal_error("MAXIMUM outgoing stream capacity reached")
          end
        end
        id = @id_counter += 2
        raise Error.internal_error("STREAM #{id} already exists") if @streams[id]?
        @streams[id] = Stream.new(@connection, id, state: state)
      end
    end

    # Counts active ingoing (type=1) or outgoing (type=0) streams.
    protected def active_count(type)
      @streams.reduce(0) do |count, (_, stream)|
        if stream.id == 0 || stream.id % 2 == type && stream.active?
          count + 1
        else
          count
        end
      end
    end

    protected def last_stream_id
      @mutex.synchronize do
        if @streams.any?
          @streams.keys.max
        else
          0
        end
      end
    end
  end
end
