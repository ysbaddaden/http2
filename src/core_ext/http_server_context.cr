require "http/server/context"

class HTTP::Server
  class Context
    # :nodoc:
    def initialize(@request : Request, @response : Response, @stream : HTTP2::Stream? = nil)
    end

    def trailers : Headers?
      @stream.try(&.trailers?)
    end
  end
end
