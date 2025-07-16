require "openssl"
require "../src/server"

class EchoHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    request, response = context.request, context.response

    if request.method == "PUT" && request.path == "/echo"
      response.headers["server"] = "h2/0.0.0"

      if len = request.content_length
        response.headers["content-length"] = len.to_s
      end
      if type = request.headers["content-type"]?
        response.headers["content-type"] = type
      end

      buffer = Bytes.new(8192)

      loop do
        count = request.body.try(&.read(buffer)) || 0
        break if count == 0
        response.write(buffer[0, count])
      end

      return
    end

    call_next(context)
  end
end

class NotFoundHandler
  include HTTP::Handler

  def call(context : HTTP::Server::Context)
    response = context.response
    response.status_code = 404
    response.headers["server"] = "h2/0.0.0"
    response.headers["content-type"] = "text/plain"
    response << "404 NOT FOUND\n"
  end
end

unless ENV["CI"]?
  HTTP2::Log.level = Log::Severity::Trace
end

host = ENV["HOST"]? || "::"
port = (ENV["PORT"]? || 9292).to_i

server = HTTP::Server.new([
  EchoHandler.new,
  NotFoundHandler.new,
])

if ENV["TLS"]?
  ssl_context = OpenSSL::SSL::Context::Server.new
  ssl_context.certificate_chain = File.join(__DIR__, "ssl", "server.crt")
  ssl_context.private_key = File.join(__DIR__, "ssl", "server.key")
  server.bind_tls(host, port, ssl_context)
else
  server.bind_tcp(host, port)
end

if ssl_context
  puts "listening on https://#{host}:#{port}/"
else
  puts "listening on http://#{host}:#{port}/"
end

server.listen
