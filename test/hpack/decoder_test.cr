require "../test_helper"
require "../../src/hpack"

module HTTP2::HPACK
  class DecoderTest < Minitest::Test
    def d
      @d ||= Decoder.new
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.2.1
    def test_literal_header_with_indexing
      headers = d.decode(slice(0x40, 0x0a, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d,
                               0x2d, 0x6b, 0x65, 0x79, 0x0d, 0x63, 0x75, 0x73,
                               0x74, 0x6f, 0x6d, 0x2d, 0x68, 0x65, 0x61, 0x64,
                               0x65, 0x72))
      assert_equal HTTP::Headers{ "custom-key" => "custom-header" }, headers
      assert_equal 1, d.table.size
      assert_equal({"custom-key", "custom-header"}, d.indexed(62))
      assert_equal 55, d.table.bytesize
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.2.2
    def test_literal_header_without_indexing
      headers = d.decode(slice(0x04, 0x0c, 0x2f, 0x73, 0x61, 0x6d, 0x70, 0x6c,
                               0x65, 0x2f, 0x70, 0x61, 0x74, 0x68))
      assert_equal HTTP::Headers{ ":path" => "/sample/path" }, headers
      assert_empty d.table
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.2.3
    def test_literal_header_never_indexed
      headers = d.decode(slice(0x10, 0x08, 0x70, 0x61, 0x73, 0x73, 0x77, 0x6f,
                               0x72, 0x64, 0x06, 0x73, 0x65, 0x63, 0x72, 0x65,
                               0x74))
      assert_equal HTTP::Headers{ "password" => "secret" }, headers
      assert_empty d.table
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.2.4
    def test_indexed_header_field
      assert_equal HTTP::Headers{ ":method" => "GET" }, d.decode(slice(0x82))
      assert_empty d.table
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.3
    def test_requests_without_huffman_coding
      # first request: http://tools.ietf.org/html/rfc7541#appendix-C.3.1
      headers = d.decode(slice(0x82, 0x86, 0x84, 0x41, 0x0f, 0x77, 0x77, 0x77,
                               0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,
                               0x2e, 0x63, 0x6f, 0x6d))
      assert_equal HTTP::Headers{
        ":method" => "GET",
        ":scheme" => "http",
        ":path" => "/",
        ":authority" => "www.example.com",
      }, headers

      assert_equal 1, d.table.size
      assert_equal 57, d.table.bytesize
      assert_equal({":authority", "www.example.com"}, d.indexed(62))

      # second request: http://tools.ietf.org/html/rfc7541#appendix-C.3.2
      headers = d.decode(slice(0x82, 0x86, 0x84, 0xbe, 0x58, 0x08, 0x6e, 0x6f,
                               0x2d, 0x63, 0x61, 0x63, 0x68, 0x65))
      assert_equal HTTP::Headers{
        ":method" => "GET",
        ":scheme" => "http",
        ":path" => "/",
        ":authority" => "www.example.com",
        "cache-control" => "no-cache",
      }, headers

      assert_equal 2, d.table.size
      assert_equal 110, d.table.bytesize
      assert_equal({"cache-control", "no-cache"}, d.indexed(62))
      assert_equal({":authority", "www.example.com"}, d.indexed(63))

      # third request: http://tools.ietf.org/html/rfc7541#appendix-C.3.3
      headers = d.decode(slice(0x82, 0x87, 0x85, 0xbf, 0x40, 0x0a, 0x63, 0x75,
                               0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x6b, 0x65, 0x79,
                               0x0c, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d,
                               0x76, 0x61, 0x6c, 0x75, 0x65))
      assert_equal HTTP::Headers{
        ":method" => "GET",
        ":scheme" => "https",
        ":path" => "/index.html",
        ":authority" => "www.example.com",
        "custom-key" => "custom-value",
      }, headers

      assert_equal 3, d.table.size
      assert_equal 164, d.table.bytesize
      assert_equal({"custom-key", "custom-value"}, d.indexed(62))
      assert_equal({"cache-control", "no-cache"}, d.indexed(63))
      assert_equal({":authority", "www.example.com"}, d.indexed(64))
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.4
    def test_requests_with_huffman_coding
      # first request: http://tools.ietf.org/html/rfc7541#appendix-C.4.1
      headers = d.decode(slice(0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2,
                               0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4,
                               0xff))
      assert_equal HTTP::Headers{
        ":method" => "GET",
        ":scheme" => "http",
        ":path" => "/",
        ":authority" => "www.example.com",
      }, headers

      assert_equal 1, d.table.size
      assert_equal 57, d.table.bytesize
      assert_equal({":authority", "www.example.com"}, d.indexed(62))

      # second request: http://tools.ietf.org/html/rfc7541#appendix-C.4.2
      headers = d.decode(slice(0x82, 0x86, 0x84, 0xbe, 0x58, 0x86, 0xa8, 0xeb,
                               0x10, 0x64, 0x9c, 0xbf))
      assert_equal HTTP::Headers{
        ":method" => "GET",
        ":scheme" => "http",
        ":path" => "/",
        ":authority" => "www.example.com",
        "cache-control" => "no-cache",
      }, headers

      assert_equal 2, d.table.size
      assert_equal 110, d.table.bytesize
      assert_equal({"cache-control", "no-cache"}, d.indexed(62))
      assert_equal({":authority", "www.example.com"}, d.indexed(63))

      # third request: http://tools.ietf.org/html/rfc7541#appendix-C.4.3
      headers = d.decode(slice(0x82, 0x87, 0x85, 0xbf, 0x40, 0x88, 0x25, 0xa8,
                               0x49, 0xe9, 0x5b, 0xa9, 0x7d, 0x7f, 0x89, 0x25,
                               0xa8, 0x49, 0xe9, 0x5b, 0xb8, 0xe8, 0xb4, 0xbf))
      assert_equal HTTP::Headers{
        ":method" => "GET",
        ":scheme" => "https",
        ":path" => "/index.html",
        ":authority" => "www.example.com",
        "custom-key" => "custom-value",
      }, headers

      assert_equal 3, d.table.size
      assert_equal 164, d.table.bytesize
      assert_equal({"custom-key", "custom-value"}, d.indexed(62))
      assert_equal({"cache-control", "no-cache"}, d.indexed(63))
      assert_equal({":authority", "www.example.com"}, d.indexed(64))
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.5
    def test_responses_without_huffman_encoding
      skip
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.6
    def test_responses_with_huffman_encoding
      skip
    end

    def slice(*bytes)
      Slice(UInt8).new(bytes.size) { |i| bytes[i].to_u8 }
    end
  end
end
