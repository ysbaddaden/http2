require "./src/server"

port = ENV.fetch("PORT", "9292").to_i
host = ENV.fetch("HOST", "::")

server = HTTP::Server.new(host, port) do |context|
  request, response = context.request, context.response
  response.headers["Content-Type"] = "text/plain"
  response << "Served with #{request.version}"
end

server.listen
