require "openssl"
require "./lib_ssl"

module OpenSSL
  module SSL
    class Context
      def initialize(method : LibSSL::SSLMethod)
        @handle = LibSSL.ssl_ctx_new(method)
      end

      def options=(options)
        LibSSL.ssl_ctx_ctrl(@handle, LibSSL::SSL_CTRL_OPTIONS, options, nil)
      end

      def clear_options(options = 0)
        LibSSL.ssl_ctx_ctrl(@handle, LibSSL::SSL_CTRL_CLEAR_OPTIONS, options, nil)
      end

      def options
        LibSSL.ssl_ctx_ctrl(@handle, LibSSL::SSL_CTRL_OPTIONS, 0, nil)
      end

      def mode=(mode)
        LibSSL.ssl_ctx_ctrl(@handle, LibSSL::SSL_CTRL_MODE, mode, nil)
      end

      def clear_mode(mode = 0)
        LibSSL.ssl_ctx_ctrl(@handle, LibSSL::SSL_CTRL_CLEAR_MODE, mode, nil)
      end

      def mode
        LibSSL.ssl_ctx_ctrl(@handle, LibSSL::SSL_CTRL_MODE, 0, nil)
      end

      def ciphers=(ciphers : String)
        LibSSL.ssl_ctx_set_cipher_list(@handle, ciphers)
        nil
      end

      def set_tmp_ecdh_key(curve = LibSSL::NID_X9_62_prime256v1)
        key = LibSSL.ec_key_new_by_curve_name(curve)
        LibSSL.ssl_ctx_ctrl(@handle, LibSSL::SSL_CTRL_SET_TMP_ECDH, 0, key)
        LibSSL.ec_key_free(key)
        nil
      end

      def alpn_protocol=(protocol : String)
        proto = Slice(UInt8).new(protocol.bytesize + 1)
        proto[0] = protocol.bytesize.to_u8
        protocol.to_slice.copy_to(proto.to_unsafe + 1, protocol.bytesize)
        self.alpn_protocol = proto
      end

      def alpn_protocol=(protocol : Slice(UInt8))
        alpn_cb = ->(ssl : LibSSL::SSL, o : LibC::Char**, olen : LibC::Char*, i : LibC::Char*, ilen : LibC::Int, data : Void*) {
          proto = Box(Slice(UInt8)).unbox(data)
          ret = LibSSL.ssl_select_next_proto(o, olen, proto, 2, i, ilen)
          if ret != LibSSL::OPENSSL_NPN_NEGOTIATED
            LibSSL::SSL_TLSEXT_ERR_NOACK
          else
            LibSSL::SSL_TLSEXT_ERR_OK
          end
        }
        LibSSL.ssl_ctx_set_alpn_select_cb(@handle, alpn_cb, Box.box(protocol) as Void*)
        nil
      end
    end
  end
end
