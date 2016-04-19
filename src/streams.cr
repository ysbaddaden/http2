require "./stream"

module HTTP2
  class Streams
    # FIXME: use even-numbered ids (incoming) and odd-numbered ids (outgoing) when Connection is CLIENT

    def initialize(@connection : Connection)
      @streams = {} of Int32 => Stream
      @id_counter = 0
      @mutex = Mutex.new
    end

    # Finds an incoming stream, silently creating it if it doesn't exist yet.
    def find(id)
      @mutex.synchronize do
        if max = @connection.local_settings.max_concurrent_streams
          if active_count(1) >= max
            raise Error.refused_stream("MAXIMUM capacity reached")
          end
        end
        @streams[id] ||= Stream.new(@connection, id)
      end
    end

    # Returns true if the incoming stream id is valid for the current connection.
    def valid?(id)
      id == 0 || (id % 2) == 1
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
      @streams.reduce(0) do |count, _, stream|
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
