require "http/headers"

struct HTTP::Headers
  # :nodoc:
  PSEUDO_HEADER_NAMES = {":status", ":method", ":path", ":authority", ":scheme"}

  private def check_invalid_header_name(key)
    previous_def unless key.in?(PSEUDO_HEADER_NAMES)
  end

  # :nodoc:
  #
  # Returns true if *string* is a token (RFC 9110 section 5.6.2), as a
  # method or a field name must be. The standard library only has it from
  # Crystal 1.20.
  def self.token?(string : String) : Bool
    !string.empty? && string.each_byte.all? { |byte| token_byte?(byte) }
  end

  private def self.token_byte?(byte : UInt8) : Bool
    byte.unsafe_chr.ascii_alphanumeric? || "!#$%&'*+-.^_`|~".includes?(byte.unsafe_chr)
  end
end
