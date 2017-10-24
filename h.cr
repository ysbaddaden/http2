require "./src/server"

port = ENV.fetch("PORT", "9292").to_i
host = ENV.fetch("HOST", "::")
tls = ENV.fetch("TLS", "false") == "true"

server = HTTP::Server.new(host, port) do |context|
  request, response = context.request, context.response
  authority = request.headers[":authority"]? || request.headers["Host"]?

  response.headers["Content-Type"] = "text/plain"
  response << "Received #{request.method} #{request.path} (#{authority})\n"
  response << "Served with #{request.version}\n"

  if request.method == "PUT" && request.path == "/upload"
    buffer = uninitialized UInt8[8192]
    response << "Reading DATA:\n"
    size = 0

    loop do
      read_bytes = context.stream.data.read(buffer.to_slice)
      break if read_bytes == 0

      size += read_bytes
      response << "  #{size}\n"

      Fiber.yield
    end
  end
end

if ENV["CI"]?
  server.logger = Logger::Dummy.new(File.open("/dev/null"))
end

if tls
  tls_context = HTTP::Server.default_tls_context
  tls_context.certificate_chain = File.join("ssl", "server.crt")
  tls_context.private_key = File.join("ssl", "server.key")
  server.tls = tls_context
end

puts "Listening on #{host}:#{port} tls=#{tls}"
server.listen
