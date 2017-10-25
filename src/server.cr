{% unless flag?(:without_openssl) %}
  require "openssl"
{% end %}
require "http/server"
require "./server/context"
require "./server/request_processor"
require "./connection"

module HTTP
  # Overloads HTTP::Server to add support HTTP/2 connections along with HTTP/1
  # connections.
  class Server
    {% unless flag?(:without_openssl) %}
      # Returns the default OpenSSL context, suitable for HTTP/2,
      # with ALPN protocol negotiation.
      def self.default_tls_context : OpenSSL::SSL::Context::Server
        tls_context = OpenSSL::SSL::Context::Server.new
        tls_context.alpn_protocol = "h2"
        tls_context
      end
    {% end %}

    @logger : Logger?

    def logger
      @logger ||= Logger.new(STDOUT).tap do |logger|
        logger.level = Logger::Severity::INFO
        logger.formatter = Logger::Formatter.new do |s, d, p, message, io|
          io << message
        end
      end
    end

    def logger=(@logger)
    end

    def handle_client(io)
      return unless io
      io.sync = true

      alpn = nil

      {% unless flag?(:without_openssl) %}
        if tls = @tls
          io = OpenSSL::SSL::Socket::Server.new(io, tls, sync_close: true)
          {% if LibSSL::OPENSSL_102 %}
            alpn = io.alpn_protocol
          {% end %}
        end
      {% end %}

      @processor.process(io, alpn, logger)
    end
  end
end
