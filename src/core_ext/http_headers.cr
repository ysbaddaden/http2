require "http/headers"

struct HTTP::Headers
  private def check_invalid_header_name(key)
    previous_def unless key.in?(":status", ":method", ":path", ":authority", ":scheme")
  end
end
