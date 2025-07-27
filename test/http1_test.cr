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
    path = "a" * (HTTP::MAX_REQUEST_LINE_SIZE - 14)
    c = connection("GET #{path} HTTP/1.1\r\n")
    assert_equal({"GET", path}, c.read_request_line)

    path = "a" * (HTTP::MAX_REQUEST_LINE_SIZE - 13)
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

  private def connection(data)
    puts
    puts data
    p HTTP1::Connection.new(IO::Memory.new(data))
  end
end
