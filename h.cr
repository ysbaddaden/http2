require "./src/server"

port = ENV.fetch("PORT", "9292").to_i
host = ENV.fetch("HOST", "::")

server = HTTP::Server.new(host, port) do |context|
  request, response = context.request, context.response
  authority = request.headers[":authority"] || request.headers["Host"]

  response.headers["Content-Type"] = "text/plain"
  response << "Received #{request.method} #{request.path} (#{authority})\n"
  response << "Served with #{request.version}\n"
end

server.listen
