require "./stream"

module HTTP2
  class Streams
    # FIXME: use even-numbered ids (incoming) and odd-numbered ids (outgoing) when Connection is CLIENT

    def initialize(@connection : Connection)
      @streams = {} of Int32 => Stream
      @id_counter = 0
      @mutex = Mutex.new
      @highest_remote_id = 0
    end

    # Finds an incoming stream, silently creating it if it doesn't exist yet.
    #
    # Takes care to increment `highest_remote_id` counter, unless `consume` is
    # set to false, for example a PRIORITY frame forward declares a stream
    # priority/dependency but doesn't consume the stream identifiers, so they
    # are still valid.
    def find(id, consume = true)
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

    def each
      @mutex.synchronize do
        @streams.each { |_, stream| yield stream }
      end
    end

    # Returns true if the incoming stream id is valid for the current connection.
    def valid?(id)
      id == 0 || (                   # stream #0 is always valid
        (id % 2) == 1 &&             # incoming streams are odd-numbered
          id >= @highest_remote_id   # stream ids must grow (not shrink)
      )
    end

    # Creates an outgoing stream.
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

    private def active_count(type)
      @streams.reduce(0) do |count, (_, stream)|
        if stream.id == 0 || stream.id % 2 == type && stream.active?
          count + 1
        else
          count
        end
      end
    end

    def last_stream_id
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
