module HTTP2
  class Error < Exception
    enum Code : UInt32
      NO_ERROR = 0x0
      PROTOCOL_ERROR = 0x1
      INTERNAL_ERROR = 0x2
      FLOW_CONTROL_ERROR = 0x3
      SETTINGS_TIMEOUT = 0x4
      STREAM_CLOSED = 0x5
      FRAME_SIZE_ERROR = 0x6
      REFUSED_STREAM = 0x7
      CANCEL = 0x8
      COMPRESSION_ERROR = 0x9
      CONNECT_ERROR = 0xa
      ENHANCE_YOUR_CALM = 0xb
      INADEQUATE_SECURITY = 0xc
      HTTP_1_1_REQUIRED = 0xd
    end

    getter code : Code
    getter last_stream_id : UInt32

    def initialize(@code : Code, last_stream_id = 0, message = "")
      @last_stream_id = last_stream_id.to_u32
      super(message)
    end

    {% for code in Code.constants %}
      def self.{{ code.downcase }}(message = "")
        new Code::{{ code.id }}, 0, message
      end
    {% end %}
  end

  class ClientError < Error
  end
end
