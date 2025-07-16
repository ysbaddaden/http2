require "http/request"

class HTTP::Request
  # :nodoc:
  #
  # Custom constructor to create Request from HTTP1::Connection and
  # HTTP2::Connection alike, avoiding to dup *headers* for example.
  def initialize(@headers : Headers, @body : IO?, @version : String)
    @method = headers[":method"]
    @resource = headers[":path"]
  end

  def scheme : String?
    @headers[":scheme"]?
  end

  def authority : String?
    @headers[":authority"]? || @headers["host"]?
  end

  def hostname : String?
    return unless authority = self.authority

    host, _, port = authority.rpartition(':')
    if host.empty?
      # no colon in authority
      host = authority
    else
      port = port.to_i?(whitespace: false)
      unless port && Socket::IPAddress.valid_port?(port)
        # what we identified as port is not valid, so use the entire authority
        host = authority
      end
    end

    URI.unwrap_ipv6(host)
  end

  def keep_alive?
    if connection = @headers["connection"]?
      if connection.compare("keep-alive", case_insensitive: true) == 0
        return true
      elsif connection.compare("close", case_insensitive: true) == 0
        return false
      elsif connection.compare("upgrade", case_insensitive: true) == 0
        return false
      end
    end
    @version == "HTTP/1.1"
  end
end
