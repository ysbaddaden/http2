class HTTP::Server
  # Instances of this class are passed to an `HTTP::Server` handler.
  class Context
    # The `HTTP::Request` to process.
    getter request : Request

    # The `HTTP::Server::Response` to configure and write to.
    getter response : Response

    # The associated `HTTP2::Stream`.
    getter! stream : HTTP2::Stream

    # :nodoc:
    def initialize(@request : Request, @response : Response, @stream : HTTP2::Stream? = nil)
    end
  end
end
