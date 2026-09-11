require "./test_helper"
require "../src/http1"

class HTTP1::ConnectionTest < Minitest::Test
  def test_read_request_line
    %w[CONNECT DELETE HEAD GET OPTIONS PATCH POST PUT TRACE xyz x].each do |method|
      %w[HTTP/1.0 HTTP/1.1].each do |version|
        c = connection("#{method} / #{version}\r\n")
        assert_equal({method, "/"}, c.read_request_line)
        assert_equal version, c.version

        c = connection("#{method} /path/to/somewhere?with=value%20and%20data #{version}\r\n")
        assert_equal({method, "/path/to/somewhere?with=value%20and%20data"}, c.read_request_line)
        assert_equal version, c.version

        # SP can be multiple SP
        c = connection("#{method}  /   #{version}  \r\n")
        assert_equal({method, "/"}, c.read_request_line)
        assert_equal version, c.version

        # no CR before LF
        c = connection("#{method} / #{version}\n")
        assert_equal({method, "/"}, c.read_request_line)
        assert_equal version, c.version
      end

      # request-target can be an URI (for example proxy intermediary)
      c = connection("#{method} http://host/path HTTP/1.1\r\n")
      assert_equal({"#{method}", "http://host/path"}, c.read_request_line)
      assert_equal "HTTP/1.1", c.version

      c = connection("#{method} http://host.domain:port/path HTTP/1.1\r\n")
      assert_equal({"#{method}", "http://host.domain:port/path"}, c.read_request_line)
      assert_equal "HTTP/1.1", c.version
    end

    # HTTP/2.0
    c = connection("PRI * HTTP/2.0\r\n")
    assert_equal({"PRI", "*"}, c.read_request_line)
    assert_equal "HTTP/2.0", c.version

    # limited request max line size
    path = "a" * (8192 - 14)
    c = connection("GET #{path} HTTP/1.1\r\n")
    assert_equal({"GET", path}, c.read_request_line)

    path = "a" * (8192 - 13)
    c = connection("GET #{path} HTTP/1.1\r\n")
    assert_equal(HTTP::Status::URI_TOO_LONG, c.read_request_line)

    path = "a" * (32 - 14)
    c = connection("GET #{path} HTTP/1.1\r\n")
    c.max_request_line_size = 32
    assert_equal({"GET", path}, c.read_request_line)

    path = "a" * (32 - 13)
    c = connection("GET #{path} HTTP/1.1\r\n")
    c.max_request_line_size = 32
    assert_equal(HTTP::Status::URI_TOO_LONG, c.read_request_line)

    # EOF
    c = connection("")
    assert_nil c.read_request_line

    # INVALID: missing request-target and HTTP-version
    c = connection("GET\r\n")
    assert_equal(HTTP::Status::BAD_REQUEST, c.read_request_line)

    # INVALID: missing HTTP-version
    c = connection("GET / \r\n")
    assert_equal(HTTP::Status::BAD_REQUEST, c.read_request_line)

    # INVALID: invalid HTTP-version
    c = connection("GET / HTTP/3.0\r\n")
    assert_equal(HTTP::Status::BAD_REQUEST, c.read_request_line)
  end

  def test_read_status_line
    c = connection("HTTP/1.0 200 OK\r\n")
    assert_equal({"HTTP/1.0", 200, "OK"}, c.read_status_line)

    # status
    100.upto(999) do |i|
      c = connection("HTTP/1.0 #{i} \r\n")
      assert_equal({"HTTP/1.0", i, ""}, c.read_status_line)
    end

    # reason-phrase is optional
    c = connection("HTTP/1.0 200 \r\n")
    assert_equal({"HTTP/1.0", 200, ""}, c.read_status_line)

    # allow SP+, trailing SP after reason phrase
    c = connection("HTTP/1.0   200   OK   \r\n")
    assert_equal({"HTTP/1.0", 200, "OK"}, c.read_status_line)

    # allow no SP before missing reason-phrase
    c = connection("HTTP/1.0   200\r\n")
    assert_equal({"HTTP/1.0", 200, ""}, c.read_status_line)

    # limited status max line size
    reason = "a" * (4096 - 14)
    c = connection("HTTP/1.1 200 #{reason}\r\n")
    assert_equal({"HTTP/1.1", 200, reason}, c.read_status_line)

    c = connection("HTTP/1.1 200 #{reason}a\r\n")
    assert_nil c.read_status_line

    spaces = " " * (4096 - 13)
    c = connection("HTTP/1.1#{spaces}200 \r\n")
    assert_equal({"HTTP/1.1", 200, ""}, c.read_status_line)

    c = connection("HTTP/1.1#{spaces} 200 \r\n")
    assert_nil c.read_status_line

    c = connection("HTTP/1.1  200  OK \r\n")
    c.max_status_line_size = 18
    assert_nil c.read_status_line

    # EOF
    c = connection("")
    assert_nil c.read_status_line

    # INVALID: invalid HTTP-version
    c = connection("HTTP/1 200 OK\r\n")
    assert_nil c.read_status_line

    c = connection("HTTP/2.0 200 OK\r\n")
    assert_nil c.read_status_line

    # INVALID: missing status
    c = connection("HTTP/1.0  OK\r\n")
    assert_nil c.read_status_line

    c = connection("HTTP/1.0\r\n")
    assert_nil c.read_status_line

    # INVALID: missing SP before status
    c = connection("HTTP/1.0200 OK\r\n")
    assert_nil c.read_status_line

    # INVALID: invalid status
    0.upto(99) do |i|
      c = connection("HTTP/1.0 #{i} \r\n")
      assert_nil c.read_status_line
    end
    c = connection("HTTP/1.0 1000 \r\n")
    assert_nil c.read_status_line

    # INVALID: missing SP before reason-phrase
    c = connection("HTTP/1.0 200OK\r\n")
    assert_nil c.read_status_line
  end

  def test_read_fields
    c = connection("name:value\r\n\r\n")
    c.read_fields(headers = HTTP::Headers.new)
    assert_equal HTTP::Headers{"name" => "value"}, headers

    # field-name = token
    c = connection("some-name: value\r\n\r\n")
    c.read_fields(headers = HTTP::Headers.new)
    assert_equal HTTP::Headers{"some-name" => "value"}, headers

    # OWS around value
    c = connection("name:  value   \r\n\r\n")
    c.read_fields(headers = HTTP::Headers.new)
    assert_equal HTTP::Headers{"name" => "value"}, headers

    # multiple fields
    fields = %w[
      accept-charset
      accept-encoding
      accept-language
      accept-ranges
      accept
      access-control-allow-origin
      age
      allow
      authorization
      cache-control
      content-disposition
      content-encoding
      content-language
      content-length
      content-location
      content-range
      content-type
      cookie
      date
      etag
      expect
      expires
      from
      host
      if-match
      if-modified-since
      if-none-match
      if-range
      if-unmodified-since
      last-modified
      link
      location
      max-forwards
      proxy-authenticate
      proxy-authorization
      range
      referer
      refresh
      retry-after
      server
      set-cookie
      strict-transport-security
      transfer-encoding
      user-agent
      vary
      via
      www-authenticate
    ].map { |name| "#{name}: value" }.join("\r\n")

    c = connection("#{fields}\r\n\r\n")
    c.read_fields(headers = HTTP::Headers.new)

    assert_equal HTTP::Headers{
      "accept-charset" => "value",
      "accept-encoding" => "value",
      "accept-language" => "value",
      "accept-ranges" => "value",
      "accept" => "value",
      "access-control-allow-origin" => "value",
      "age" => "value",
      "allow" => "value",
      "authorization" => "value",
      "cache-control" => "value",
      "content-disposition" => "value",
      "content-encoding" => "value",
      "content-language" => "value",
      "content-length" => "value",
      "content-location" => "value",
      "content-range" => "value",
      "content-type" => "value",
      "cookie" => "value",
      "date" => "value",
      "etag" => "value",
      "expect" => "value",
      "expires" => "value",
      "from" => "value",
      "host" => "value",
      "if-match" => "value",
      "if-modified-since" => "value",
      "if-none-match" => "value",
      "if-range" => "value",
      "if-unmodified-since" => "value",
      "last-modified" => "value",
      "link" => "value",
      "location" => "value",
      "max-forwards" => "value",
      "proxy-authenticate" => "value",
      "proxy-authorization" => "value",
      "range" => "value",
      "referer" => "value",
      "refresh" => "value",
      "retry-after" => "value",
      "server" => "value",
      "set-cookie" => "value",
      "strict-transport-security" => "value",
      "transfer-encoding" => "value",
      "user-agent" => "value",
      "vary" => "value",
      "via" => "value",
      "www-authenticate" => "value",
    }, headers

    # INVALID: OWS (SP, HTAB) before COLON
    c = connection("badname : value\r\n\r\n")
    assert_equal HTTP::Status::BAD_REQUEST, c.read_fields(headers = HTTP::Headers.new)
    assert_empty headers

    c = connection(" badname: value\r\n\r\n")
    assert_equal HTTP::Status::BAD_REQUEST, c.read_fields(headers = HTTP::Headers.new)
    assert_empty headers

    c = connection("bad\tname: value\r\n\r\n")
    assert_equal HTTP::Status::BAD_REQUEST, c.read_fields(headers = HTTP::Headers.new)
    assert_empty headers
  end

  def test_read_chunk_line
    c = connection("0\r\n")
    assert_equal 0, c.read_chunk_line

    c = connection("A0\r\n")
    assert_equal 0xa0, c.read_chunk_line

    c = connection("fa0945\r\n")
    assert_equal 0xfa0945, c.read_chunk_line

    c = connection("5; whatever\r\n")
    assert_equal 0x5, c.read_chunk_line

    c = connection("123 ; whatever\r\n")
    assert_equal 0x123, c.read_chunk_line

    c = connection("123\t; whatever\r\n")
    assert_equal 0x123, c.read_chunk_line

    c = connection("acB0; key=value; another=one\r\n")
    assert_equal 0xacb0, c.read_chunk_line

    # EOF
    c = connection("")
    assert_nil c.read_chunk_line

    # INVALID: missing size
    c = connection("\r\n")
    assert_nil c.read_chunk_line

    # INVALID: invalid size
    c = connection("g\r\n")
    assert_nil c.read_chunk_line

    c = connection("1fg\r\n")
    assert_nil c.read_chunk_line
  end

  def test_content
    headers = HTTP::Headers.new
    c = connection("")
    assert_nil c.content(headers, mandatory: false)

    assert_instance_of HTTP::UnknownLengthContent, content = c.content(headers, mandatory: true)
    assert_equal "", content.try(&.gets_to_end)
    refute c.faulty?
    refute content.@expects_continue if content

    headers = HTTP::Headers{"expect" => "100-continue"}
    c = connection("")
    assert_instance_of HTTP::UnknownLengthContent, content = c.content(headers, mandatory: true)
    assert content.@expects_continue if content

    headers = HTTP::Headers.new
    c = connection("12345")
    assert_instance_of HTTP::UnknownLengthContent, content = c.content(headers, mandatory: true)
    assert_equal "12345", content.try(&.gets_to_end)
    refute c.faulty?
  end

  def test_fixed_length_content
    headers = HTTP::Headers{"content-length" => "0"}
    c = connection("")
    assert_instance_of HTTP::FixedLengthContent, content = c.content(headers)
    assert_equal "", content.try(&.gets_to_end)
    refute c.faulty?

    headers = HTTP::Headers{"content-length" => "5"}
    c = connection("12345")
    assert_instance_of HTTP::FixedLengthContent, content = c.content(headers)
    assert_equal "12345", content.try(&.gets_to_end)
    refute c.faulty?
  end

  def test_chunked_content
    headers = HTTP::Headers{"transfer-encoding" => "chunked"}
    c = connection("0\r\n\r\n")
    assert_instance_of HTTP::ChunkedContent, content = c.content(headers)
    assert_equal "", content.try(&.gets_to_end)
    refute c.faulty?

    headers = HTTP::Headers{"transfer-encoding" => "chunked"}
    c = connection("5\r\n123450\r\n\r\n")
    assert_instance_of HTTP::ChunkedContent, content = c.content(headers)
    assert_equal "12345", content.try(&.gets_to_end)
    refute c.faulty?

    # ignores content-length and reports faulty connection state (must close the
    # connection after handling the request or response).
    headers = HTTP::Headers{"content-length" => "0", "transfer-encoding" => "chunked"}
    c = connection("0\r\n\r\n")
    assert_instance_of HTTP::ChunkedContent, c.content(headers)
    assert_equal "", content.try(&.gets_to_end)
    assert c.faulty?
  end

  def test_chunked_content_with_trailer_section
    headers = HTTP::Headers{"transfer-encoding" => "chunked"}
    c = connection("5\r\n123450\r\nsome-name: value\r\n\r\n")

    content = c.content(headers).as(HTTP::ChunkedContent)
    assert_nil content.trailers?

    assert_equal "12345", content.try(&.gets_to_end)
    assert_equal HTTP::Headers{"some-name" => "value"}, content.trailers?
  end

  def test_http_upgrade
    c = HTTP1::Connection.new(io = IO::Memory.new)
    c.http_upgrade("h2c")
    assert_equal <<-HTTP, io.rewind.to_s
      HTTP/1.1 101 Switching Protocols\r
      Connection: Upgrade\r
      Upgrade: h2c\r
      \r\n
      HTTP
  end

  def test_write_request_line
    [
      {"GET", "/"},
      {"GET", "/?query=value&more"},
      {"PATH", "/path?query=value&more"},
      {"POST", "/path/to/somewhere"},
    ].each do |(method, path)|
      c = HTTP1::Connection.new(io = IO::Memory.new, "HTTP/1.0")
      c.write_request_line method, path
      assert_equal "#{method} #{path} HTTP/1.0\r\n", io.rewind.to_s

      c = HTTP1::Connection.new(io = IO::Memory.new, "HTTP/1.1")
      c.write_request_line method, path
      assert_equal "#{method} #{path} HTTP/1.1\r\n", io.rewind.to_s
    end
  end

  def test_write_status_line
    [
      {200, "OK"},
      {400, "Bad Request"},
      {500, "WhaTevER YoU WanT"},
      {"404", ""},
      {"200", nil},
    ].each do |(status, description)|
      c = HTTP1::Connection.new(io = IO::Memory.new, "HTTP/1.0")
      c.write_status_line status, description
      assert_equal "HTTP/1.0 #{status} #{description}\r\n", io.rewind.to_s

      c = HTTP1::Connection.new(io = IO::Memory.new, "HTTP/1.1")
      c.write_status_line status, description
      assert_equal "HTTP/1.1 #{status} #{description}\r\n", io.rewind.to_s
    end
  end

  def test_write_fields
    skip "todo"
  end

  def test_send_headers
    skip "todo"
  end

  def test_send_data
    skip "todo"
  end

  def test_flush
    skip "todo"
  end

  private def connection(data)
    HTTP1::Connection.new(IO::Memory.new(data))
  end
end
