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
      assert_equal HTTP::Headers{"custom-key" => "custom-header"}, headers
      assert_equal 1, d.table.size
      assert_equal({"custom-key", "custom-header"}, d.indexed(62))
      assert_equal 55, d.table.bytesize
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.2.2
    def test_literal_header_without_indexing
      headers = d.decode(slice(0x04, 0x0c, 0x2f, 0x73, 0x61, 0x6d, 0x70, 0x6c,
                               0x65, 0x2f, 0x70, 0x61, 0x74, 0x68))
      assert_equal HTTP::Headers{":path" => "/sample/path"}, headers
      assert_empty d.table
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.2.3
    def test_literal_header_never_indexed
      headers = d.decode(slice(0x10, 0x08, 0x70, 0x61, 0x73, 0x73, 0x77, 0x6f,
        0x72, 0x64, 0x06, 0x73, 0x65, 0x63, 0x72, 0x65,
        0x74))
      assert_equal HTTP::Headers{"password" => "secret"}, headers
      assert_empty d.table
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.2.4
    def test_indexed_header_field
      assert_equal HTTP::Headers{":method" => "GET"}, d.decode(slice(0x82))
      assert_empty d.table
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.3
    def test_requests_without_huffman_coding
      # first request: http://tools.ietf.org/html/rfc7541#appendix-C.3.1
      headers = d.decode(slice(0x82, 0x86, 0x84, 0x41, 0x0f, 0x77, 0x77, 0x77,
                               0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70, 0x6c, 0x65,
                               0x2e, 0x63, 0x6f, 0x6d))
      assert_equal HTTP::Headers{
        ":method"    => "GET",
        ":scheme"    => "http",
        ":path"      => "/",
        ":authority" => "www.example.com",
      }, headers

      assert_equal 1, d.table.size
      assert_equal 57, d.table.bytesize
      assert_equal({":authority", "www.example.com"}, d.indexed(62))

      # second request: http://tools.ietf.org/html/rfc7541#appendix-C.3.2
      headers = d.decode(slice(0x82, 0x86, 0x84, 0xbe, 0x58, 0x08, 0x6e, 0x6f,
                               0x2d, 0x63, 0x61, 0x63, 0x68, 0x65))
      assert_equal HTTP::Headers{
        ":method"       => "GET",
        ":scheme"       => "http",
        ":path"         => "/",
        ":authority"    => "www.example.com",
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
        ":method"    => "GET",
        ":scheme"    => "https",
        ":path"      => "/index.html",
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
        ":method"    => "GET",
        ":scheme"    => "http",
        ":path"      => "/",
        ":authority" => "www.example.com",
      }, headers

      assert_equal 1, d.table.size
      assert_equal 57, d.table.bytesize
      assert_equal({":authority", "www.example.com"}, d.indexed(62))

      # second request: http://tools.ietf.org/html/rfc7541#appendix-C.4.2
      headers = d.decode(slice(0x82, 0x86, 0x84, 0xbe, 0x58, 0x86, 0xa8, 0xeb,
                               0x10, 0x64, 0x9c, 0xbf))
      assert_equal HTTP::Headers{
        ":method"       => "GET",
        ":scheme"       => "http",
        ":path"         => "/",
        ":authority"    => "www.example.com",
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
        ":method"    => "GET",
        ":scheme"    => "https",
        ":path"      => "/index.html",
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
      d = Decoder.new(256)

      first = UInt8.static_array(
        0x48, 0x03 , 0x33, 0x30, 0x32, 0x58, 0x07, 0x70, 0x72, 0x69, 0x76, 0x61, 0x74, 0x65, 0x61, 0x1d,
        0x4d, 0x6f , 0x6e, 0x2c, 0x20, 0x32, 0x31, 0x20, 0x4f, 0x63, 0x74, 0x20, 0x32, 0x30, 0x31, 0x33,
        0x20, 0x32 , 0x30, 0x3a, 0x31, 0x33, 0x3a, 0x32, 0x31, 0x20, 0x47, 0x4d, 0x54, 0x6e, 0x17, 0x68,
        0x74, 0x74 , 0x70, 0x73, 0x3a, 0x2f, 0x2f, 0x77, 0x77, 0x77, 0x2e, 0x65, 0x78, 0x61, 0x6d, 0x70,
        0x6c, 0x65 , 0x2e, 0x63, 0x6f, 0x6d)
      assert_equal HTTP::Headers{
        ":status" => "302",
        "cache-control" => "private",
        "date" => "Mon, 21 Oct 2013 20:13:21 GMT",
        "location" => "https://www.example.com",
      }, d.decode(first.to_slice)

      assert_equal 4, d.table.size
      assert_equal 222, d.table.bytesize
      assert_equal({"location", "https://www.example.com"}, d.indexed(62))
      assert_equal({"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, d.indexed(63))
      assert_equal({"cache-control", "private"}, d.indexed(64))
      assert_equal({":status", "302"}, d.indexed(65))

      second = UInt8.static_array(0x48, 0x83, 0x64, 0x0e, 0xff, 0xc1, 0xc0, 0xbf)
      assert_equal HTTP::Headers{
        ":status" => "307",
        "cache-control" => "private",
        "date" => "Mon, 21 Oct 2013 20:13:21 GMT",
        "location" => "https://www.example.com",
      }, d.decode(second.to_slice)

      assert_equal 4, d.table.size
      assert_equal 222, d.table.bytesize
      assert_equal({":status", "307"}, d.indexed(62))
      assert_equal({"location", "https://www.example.com"}, d.indexed(63))
      assert_equal({"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, d.indexed(64))
      assert_equal({"cache-control", "private"}, d.indexed(65))

      third = UInt8.static_array(
        0x88, 0xc1, 0x61, 0x1d, 0x4d, 0x6f, 0x6e, 0x2c, 0x20, 0x32, 0x31, 0x20, 0x4f, 0x63, 0x74, 0x20,
        0x32, 0x30, 0x31, 0x33, 0x20, 0x32, 0x30, 0x3a, 0x31, 0x33, 0x3a, 0x32, 0x32, 0x20, 0x47, 0x4d,
        0x54, 0xc0, 0x5a, 0x04, 0x67, 0x7a, 0x69, 0x70, 0x77, 0x38, 0x66, 0x6f, 0x6f, 0x3d, 0x41, 0x53,
        0x44, 0x4a, 0x4b, 0x48, 0x51, 0x4b, 0x42, 0x5a, 0x58, 0x4f, 0x51, 0x57, 0x45, 0x4f, 0x50, 0x49,
        0x55, 0x41, 0x58, 0x51, 0x57, 0x45, 0x4f, 0x49, 0x55, 0x3b, 0x20, 0x6d, 0x61, 0x78, 0x2d, 0x61,
        0x67, 0x65, 0x3d, 0x33, 0x36, 0x30, 0x30, 0x3b, 0x20, 0x76, 0x65, 0x72, 0x73, 0x69, 0x6f, 0x6e,
        0x3d, 0x31)
      assert_equal HTTP::Headers{
        ":status" => "200",
        "cache-control" => "private",
        "date" => "Mon, 21 Oct 2013 20:13:22 GMT",
        "location" => "https://www.example.com",
        "content-encoding" => "gzip",
        "set-cookie" => "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
      }, d.decode(third.to_slice)

      assert_equal 3, d.table.size
      assert_equal 215, d.table.bytesize
      assert_equal({"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"}, d.indexed(62))
      assert_equal({"content-encoding", "gzip"}, d.indexed(63))
      assert_equal({"date", "Mon, 21 Oct 2013 20:13:22 GMT"}, d.indexed(64))
    end

    # http://tools.ietf.org/html/rfc7541#appendix-C.6
    def test_responses_with_huffman_encoding
      d = Decoder.new(256)

      first = UInt8.static_array(
        0x48, 0x82, 0x64, 0x02, 0x58, 0x85, 0xae, 0xc3, 0x77, 0x1a, 0x4b, 0x61, 0x96, 0xd0, 0x7a, 0xbe,
        0x94, 0x10, 0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05, 0x95, 0x04, 0x0b, 0x81, 0x66, 0xe0, 0x82, 0xa6,
        0x2d, 0x1b, 0xff, 0x6e, 0x91, 0x9d, 0x29, 0xad, 0x17, 0x18, 0x63, 0xc7, 0x8f, 0x0b, 0x97, 0xc8,
        0xe9, 0xae, 0x82, 0xae, 0x43, 0xd3)
      assert_equal HTTP::Headers{
        ":status" => "302",
        "cache-control" => "private",
        "date" => "Mon, 21 Oct 2013 20:13:21 GMT",
        "location" => "https://www.example.com",
      }, d.decode(first.to_slice)

      assert_equal 4, d.table.size
      assert_equal 222, d.table.bytesize
      assert_equal({"location", "https://www.example.com"}, d.indexed(62))
      assert_equal({"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, d.indexed(63))
      assert_equal({"cache-control", "private"}, d.indexed(64))
      assert_equal({":status", "302"}, d.indexed(65))

      second = UInt8.static_array(0x48, 0x83, 0x64, 0x0e, 0xff, 0xc1, 0xc0, 0xbf)
      assert_equal HTTP::Headers{
        ":status" => "307",
        "cache-control" => "private",
        "date" => "Mon, 21 Oct 2013 20:13:21 GMT",
        "location" => "https://www.example.com",
      }, d.decode(second.to_slice)

      assert_equal 4, d.table.size
      assert_equal 222, d.table.bytesize
      assert_equal({":status", "307"}, d.indexed(62))
      assert_equal({"location", "https://www.example.com"}, d.indexed(63))
      assert_equal({"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, d.indexed(64))
      assert_equal({"cache-control", "private"}, d.indexed(65))

      third = UInt8.static_array(
        0x88, 0xc1, 0x61, 0x96, 0xd0, 0x7a, 0xbe, 0x94, 0x10, 0x54, 0xd4, 0x44, 0xa8, 0x20, 0x05, 0x95,
        0x04, 0x0b, 0x81, 0x66, 0xe0, 0x84, 0xa6, 0x2d, 0x1b, 0xff, 0xc0, 0x5a, 0x83, 0x9b, 0xd9, 0xab,
        0x77, 0xad, 0x94, 0xe7, 0x82, 0x1d, 0xd7, 0xf2, 0xe6, 0xc7, 0xb3, 0x35, 0xdf, 0xdf, 0xcd, 0x5b,
        0x39, 0x60, 0xd5, 0xaf, 0x27, 0x08, 0x7f, 0x36, 0x72, 0xc1, 0xab, 0x27, 0x0f, 0xb5, 0x29, 0x1f,
        0x95, 0x87, 0x31, 0x60, 0x65, 0xc0, 0x03, 0xed, 0x4e, 0xe5, 0xb1, 0x06, 0x3d, 0x50, 0x07)
      assert_equal HTTP::Headers{
        ":status" => "200",
        "cache-control" => "private",
        "date" => "Mon, 21 Oct 2013 20:13:22 GMT",
        "location" => "https://www.example.com",
        "content-encoding" => "gzip",
        "set-cookie" => "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1",
      }, d.decode(third.to_slice)

      assert_equal 3, d.table.size
      assert_equal 215, d.table.bytesize
      assert_equal({"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"}, d.indexed(62))
      assert_equal({"content-encoding", "gzip"}, d.indexed(63))
      assert_equal({"date", "Mon, 21 Oct 2013 20:13:22 GMT"}, d.indexed(64))
    end

    def test_large_integer_literal
      bytes = Slice(UInt8).new(3 + 3 + 4096) { '.'.ord.to_u8 }
      bytes[0] = 0x00_u8
      bytes[1] = 0x01_u8
      bytes[2] = 'x'.ord.to_u8
      bytes[3] = 0x7f_u8
      bytes[4] = 0x81_u8
      bytes[5] = 0x1f_u8

      headers = d.decode(bytes)
      assert_equal "." * 4096, headers["x"]
    end

    def test_edge_integer_literal
      bytes = Slice(UInt8).new(3 + 2 + 127) { '.'.ord.to_u8 }
      bytes[0] = 0x00_u8
      bytes[1] = 0x01_u8
      bytes[2] = 'x'.ord.to_u8
      bytes[3] = 0x7f_u8
      bytes[4] = 0x00_u8

      headers = d.decode(bytes)
      assert_equal "." * 127, headers["x"]
    end

    # https://tools.ietf.org/html/rfc7541#section-5.2
    def test_rejects_padding_larger_than_7bits
      bytes = UInt8.static_array(
        0x82, 0x87, 0x84, 0x41, 0x8a, 0x08, 0x9d, 0x5c,
        0x0b, 0x81, 0x70, 0xdc, 0x7c, 0x4f, 0x8b, 0x00,
        0x85, 0xf2, 0xb2, 0x4a, 0x84, 0xff, 0x84, 0x49,
        0x50, 0x9f, 0xff)
      assert_raises(Exception) { d.decode(bytes.to_slice) }
    end

    # https://tools.ietf.org/html/rfc7541#section-5.2
    def test_rejects_non_EOS_padding
      bytes = UInt8.static_array(
        0x82, 0x87, 0x84, 0x41, 0x8a, 0x08, 0x9d, 0x5c,
        0x0b, 0x81, 0x70, 0xdc, 0x7c, 0x4f, 0x8b, 0x00,
        0x85, 0xf2, 0xb2, 0x4a, 0x84, 0xff, 0x83, 0x49,
        0x50, 0x90)
      assert_raises(Exception) { d.decode(bytes.to_slice) }
    end

    # the following tests are from the hpack crate:
    # https://github.com/mlalic/hpack-rs/blob/e833ecac324fb9457e04737f482328c3b5cc93fa/src/huffman.rs

    def test_huffman_code_single_byte
      assert_equal "o", HPACK.huffman.decode(slice(0x3f))
      assert_equal "0", HPACK.huffman.decode(slice(0x07))
      assert_equal "A", HPACK.huffman.decode(slice(0x87))
    end

    def test_huffman_code_single_char_multiple_byte
      assert_equal "#", HPACK.huffman.decode(slice(0xff, 0xaf))
      assert_equal "$", HPACK.huffman.decode(slice(0xff, 0xcf))
      assert_equal "\n", HPACK.huffman.decode(slice(0xff, 0xff, 0xff, 0xf3))
    end

    def test_huffman_code_multiple_chars
      assert_equal "!0", HPACK.huffman.decode(slice(0xfe, 0x01))
      assert_equal " !", HPACK.huffman.decode(slice(0x53, 0xf8))
    end

    def test_eos_is_error
      assert_raises { HPACK.huffman.decode(slice(0xff, 0xff, 0xff, 0xff)) }
    end

    def test_short_padding
      assert_equal "o", HPACK.huffman.decode(slice(0x3f))
    end

    def test_padding_invalid_too_long
      assert_raises { HPACK.huffman.decode(slice(0x3f, 0xff)) }
    end

    def test_padding_invalid
      assert_raises { HPACK.huffman.decode(slice(0x3e)) }
      assert_raises { HPACK.huffman.decode(slice(0xfe, 0x00)) }
    end

    def slice(*bytes)
      Slice(UInt8).new(bytes.size) { |i| bytes[i].to_u8 }
    end
  end
end
