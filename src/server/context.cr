# Instances of this class are passed to an `HTTP2::Server` handler.
#
# Overloads HTTP::Server::Context to add specific HTTP2 support methods. For
# example direct access to `stream`xi or server-push.
#
# TODO: add methods to abstract server-push support
class HTTP::Server::Context
  getter! stream : HTTP2::Stream

  # :nodoc:
  def initialize(@request : HTTP::Request, @response : Response, @stream : HTTP2::Stream? = nil)
  end

  def http1?
    @stream.nil?
  end

  def http2?
    !@stream.nil?
  end
end
