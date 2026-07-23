require "./stream"

module HTTP2
  class Streams
    enum Endpoint
      CLIENT
      SERVER

      def peer : Endpoint
        client? ? SERVER : CLIENT
      end

      def first_stream_id : Int32
        client? ? 1 : 2
      end

      def initiates?(stream_id : Int32) : Bool
        # RFC 9113 assigns odd stream IDs to client-initiated streams and even
        # stream IDs to server-initiated streams. This compares the stream ID's
        # oddness to whether this endpoint is the client; it does not rely on
        # enum numeric values.
        stream_id > 0 && stream_id.odd? == client?
      end
    end

    # :nodoc:
    protected def initialize(@connection : Connection, type : Connection::Type)
      @streams = {} of Int32 => Stream
      @mutex = Mutex.new  # OPTIMIZE: use Sync::RWLock instead
      @highest_remote_id = 0

      @local_endpoint = type.server? ? Endpoint::SERVER : Endpoint::CLIENT
      @remote_endpoint = @local_endpoint.peer
      @id_counter = @local_endpoint.first_stream_id - 2
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
          if @remote_endpoint.initiates?(id)
            if max = @connection.local_settings.max_concurrent_streams
              if unsafe_active_count_initiated_by(@remote_endpoint) >= max
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
      @mutex.synchronize do
        @streams.each { |_, stream| yield stream }
      end
    end

    # Returns true if the incoming stream id is valid for the current connection.
    protected def valid?(id : Int32)
      # Stream #0 is the connection control stream, and existing streams may
      # have been initiated by either endpoint.
      return true if id == 0
      return true if @mutex.synchronize { @streams[id]? }

      @remote_endpoint.initiates?(id) && id >= @highest_remote_id
    end

    # Creates an outgoing stream. For example to handle a client request or a
    # server push.
    def create(state = Stream::State::IDLE) : Stream
      @mutex.synchronize do
        if max = @connection.remote_settings.max_concurrent_streams
          if unsafe_active_count_initiated_by(@local_endpoint) >= max
            raise Error.refused_stream("MAXIMUM locally initiated stream capacity reached")
          end
        end
        id = @id_counter += 2
        raise Error.internal_error("STREAM #{id} already exists") if @streams[id]?
        @streams[id] = Stream.new(@connection, id, state: state)
      end
    end

    protected def active_remote_count : Int32
      @mutex.synchronize { unsafe_active_count_initiated_by(@remote_endpoint) }
    end

    private def unsafe_active_count_initiated_by(endpoint : Endpoint) : Int32
      @streams.reduce(0) do |count, (_, stream)|
        if endpoint.initiates?(stream.id) && stream.active?
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
