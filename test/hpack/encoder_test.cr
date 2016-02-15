require "../test_helper"
require "../../src/hpack"

module HTTP2::HPACK
  class EncoderTest < Minitest::Test
    def e
      @e ||= Encoder.new
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.2.1
    def test_literal_header_with_indexing
      headers = HTTP::Headers{ "custom-key" => "custom-header" }
      assert_equal slice(0x40, 0x0a, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d,
                         0x6b, 0x65, 0x79, 0x0d, 0x63, 0x75, 0x73, 0x74, 0x6f,
                         0x6d, 0x2d, 0x68, 0x65, 0x61, 0x64, 0x65, 0x72),
                         e.encode(headers, Indexing::ALWAYS)
      assert_equal 1, e.table.size
      assert_equal 55, e.table.bytesize
      assert_equal({"custom-key", "custom-header"}, e.table[0])
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.2.2
    def test_literal_header_without_indexing
      headers = HTTP::Headers{ ":path" => "/sample/path" }
      assert_equal slice(0x04, 0x0c, 0x2f, 0x73, 0x61, 0x6d, 0x70, 0x6c, 0x65,
                         0x2f, 0x70, 0x61, 0x74, 0x68),
                         e.encode(headers, Indexing::NONE)
      assert_empty e.table
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.2.3
    def test_literal_header_never_indexed
      headers = HTTP::Headers{ "password" => "secret" }
      assert_equal slice(0x10, 0x08, 0x70, 0x61, 0x73, 0x73, 0x77, 0x6f, 0x72,
                         0x64, 0x06, 0x73, 0x65, 0x63, 0x72, 0x65, 0x74),
                         e.encode(headers, Indexing::NEVER)
      assert_empty e.table
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.2.4
    def test_indexed_header_field
      assert_equal slice(0x82), e.encode(HTTP::Headers{ ":method" => "GET" })
      assert_empty e.table
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.5
    def test_responses_without_huffman_encoding
      e = Encoder.new(max_table_size: 256)

      # first response:  http://tools.ietf.org/html/rfc7541#appendix-C.5.1
      headers = HTTP::Headers{
        ":status" => "302",
        "cache-control" => "private",
        "date" => "Mon, 21 Oct 2013 20:13:21 GMT",
        "location" => "https://www.example.com",
      }
      assert_equal slice(
        0x48, 0x03, 0x33, 0x30, 0x32,
        0x58, 0x07, 0x70, 0x72, 0x69, 0x76, 0x61, 0x74, 0x65,
        0x61, 0x1d, 0x4d, 0x6f, 0x6e, 0x2c, 0x20, 0x32, 0x31, 0x20, 0x4f, 0x63, 0x74, 0x20, 0x32, 0x30, 0x31, 0x33, 0x20, 0x32, 0x30, 0x3a, 0x31, 0x33, 0x3a, 0x32, 0x31, 0x20, 0x47, 0x4d, 0x54,
        0x6e, 0x17, 0x68, 0x74, 0x74, 0x70, 0x73, 0x3a, 0x2f, 0x2f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65, 0x2e, 0x63, 0x6f, 0x6d
      ), e.encode(headers, Indexing::ALWAYS)

      assert_equal 4, e.table.size
      assert_equal 222, e.table.bytesize
      assert_equal({"location", "https://www.example.com"}, e.table[0])
      assert_equal({"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, e.table[1])
      assert_equal({"cache-control", "private"}, e.table[2])
      assert_equal({":status", "302"}, e.table[3])

      # second response:  http://tools.ietf.org/html/rfc7541#appendix-C.5.2
      headers = HTTP::Headers{
        ":status" => "307",
        "cache-control" => "private",
        "date" => "Mon, 21 Oct 2013 20:13:21 GMT",
        "location" => "https://www.example.com",
      }
      assert_equal slice(0x48, 0x03, 0x33, 0x30, 0x37, 0xc1, 0xc0, 0xbf),
        e.encode(headers, Indexing::ALWAYS)

      assert_equal 4, e.table.size
      assert_equal 222, e.table.bytesize
      assert_equal({":status", "307"}, e.table[0])
      assert_equal({"location", "https://www.example.com"}, e.table[1])
      assert_equal({"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, e.table[2])
      assert_equal({"cache-control", "private"}, e.table[3])

      # third response:  http://tools.ietf.org/html/rfc7541#appendix-C.5.3
      headers = HTTP::Headers{
        ":status" => "200",
        "cache-control" => "private",
        "date" => "Mon, 21 Oct 2013 20:13:22 GMT",
        "location" => "https://www.example.com",
        "content-encoding" => "gzip",
        "set-cookie" => "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
      }
      assert_equal slice(0x88, 0xc1, 0x61, 0x1d, 0x4d, 0x6f, 0x6e, 0x2c, 0x20,
                         0x32, 0x31, 0x20, 0x4f, 0x63, 0x74, 0x20, 0x32, 0x30,
                         0x31, 0x33, 0x20, 0x32, 0x30, 0x3a, 0x31, 0x33, 0x3a,
                         0x32, 0x32, 0x20, 0x47, 0x4d, 0x54, 0xc0, 0x5a, 0x04,
                         0x67, 0x7a, 0x69, 0x70, 0x77, 0x38, 0x66, 0x6f, 0x6f,
                         0x3d, 0x41, 0x53, 0x44, 0x4a, 0x4b, 0x48, 0x51, 0x4b,
                         0x42, 0x5a, 0x58, 0x4f, 0x51, 0x57, 0x45, 0x4f, 0x50,
                         0x49, 0x55, 0x41, 0x58, 0x51, 0x57, 0x45, 0x4f, 0x49,
                         0x55, 0x3b, 0x20, 0x6d, 0x61, 0x78, 0x2d, 0x61, 0x67,
                         0x65, 0x3d, 0x33, 0x36, 0x30, 0x30, 0x3b, 0x20, 0x76,
                         0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e, 0x3d, 0x31),
                         e.encode(headers, Indexing::ALWAYS)
      assert_equal 3, e.table.size
      assert_equal 215, e.table.bytesize
      assert_equal({"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"}, e.table[0])
      assert_equal({"content-encoding", "gzip"}, e.table[1])
      assert_equal({"date", "Mon, 21 Oct 2013 20:13:22 GMT"}, e.table[2])
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
