require "./stream"

module HTTP2
  class Streams
    def initialize(@connection : Connection)
      @streams = {} of Int32 => Stream
      @id_counter = 0
      @mutex = Mutex.new
    end

    def find_or_create(id)
      @mutex.synchronize do
        # TODO: verify that streams are within max_concurrent_streams setting
        @streams[id] ||= Stream.new(@connection, id)
      end
    end

    def create(state = Stream::State::IDLE)
      @mutex.synchronize do
        # TODO: verify that streams are within max_concurrent_streams setting
        id = @id_counter += 2
        raise Error.internal_error("STREAM #{id} already exists") if @streams[id]?
        @streams[id] = Stream.new(@connection, id, state: state)
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
