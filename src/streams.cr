module HTTP2
  class Streams
    getter root : Stream
    private getter connection : Connection
    private getter streams

    def initialize(@connection)
      @root = Stream.new(connection, 0)
      @streams = { @root.id => @root }
    end

    def [](id)
      streams[id]
    end

    def create(id, parent_id = 0, exclusive = false, weight = 16)
      streams[id] = Stream.new(connection, id, parent_id: parent_id, exclusive: exclusive, weight: weight)
    end

    def last_stream_id
      streams.keys.max || 0
    end

    def available
      # FIXME: return a stream that is *really* available, respecting priority, ...
      streams[1]
    end
  end
end
