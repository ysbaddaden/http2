module HTTP2
  class Server
    class Request
      @headers : HTTP::Headers
      @body : IO?
      @version : String

      # :nodoc:
      protected def initialize(@headers, @body, @version)
      end

      def method
        @headers[":method"]
      end

      def scheme
        @headers[":scheme"]?
      end

      def authority
        @headers[":authority"]? || @headers["host"]?
      end

      def path
        @headers[":path"]
      end

      def query
        if index = path.index('?')
          path[index..-1]
        else
          ""
        end
      end

      def version
        @version
      end

      def headers
        @headers
      end

      def content_length
        @headers["content-length"]?.try(&.to_u64?)
      end

      def host
        return unless host = authority
        if index = host.index(':')
          host[0...index]
        else
          host
        end
      end

      def cookies
        @cookies ||= HTTP::Cookies.from_header(@headers)
      end

      def body?
        @body
      end

      def body
        @body.not_nil!
      end

      def close
        @body.try(&.skip_to_end)
      end

      protected def keep_alive?
        case @headers["connection"]?
        when "keep-alive"
          true
        when "", nil
          @version == "HTTP/1.1"
        else
          false
        end
      end
    end
  end
end
