lib LibSSL
  alias Char = LibC::Char
  alias Long = LibC::Long

  alias EC_KEY = Void*

  fun tls_method = TLS_method : SSLMethod
  fun tls_client_method = TLS_client_method : SSLMethod
  fun tls_server_method = TLS_server_method : SSLMethod

  fun tlsv1_method = TLSv1_method : SSLMethod
  fun tlsv1_client_method = TLSv1_client_method : SSLMethod
  fun tlsv1_server_method = TLSv1_server_method : SSLMethod

  fun tlsv1_1_method = TLSv1_1_method : SSLMethod
  fun tlsv1_1_client_method = TLSv1_client_method : SSLMethod
  fun tlsv1_1_server_method = TLSv1_server_method : SSLMethod

  fun tlsv1_2_method = TLSv1_2_method : SSLMethod
  fun tlsv1_2_client_method = TLSv1_client_method : SSLMethod
  fun tlsv1_2_server_method = TLSv1_server_method : SSLMethod

  fun ssl_ctx_ctrl = SSL_CTX_ctrl(ctx : SSLContext, cmd : Int, larg : Long, parg : Void*) : Long
  fun ssl_ctx_set_cipher_list = SSL_CTX_set_cipher_list(ctx : SSLContext, ciphers : Char*) : Int

  alias ALPN_CB = (SSL, Char**, Char*, Char*, Int, Void*) -> Int
  fun ssl_ctx_set_alpn_select_cb = SSL_CTX_set_alpn_select_cb(ctx : SSLContext, cb : ALPN_CB, arg : Void*) : Void
  fun ssl_select_next_proto = SSL_select_next_proto(output : Char**, output_len : Char*, input : Char*, input_len : Int, client : Char*, client_len : Int) : Int

  fun ec_key_new_by_curve_name = EC_KEY_new_by_curve_name(nid : Int) : EC_KEY
  fun ec_key_free = EC_KEY_free(key : EC_KEY)

  fun ssl_ctx_set_session_id_context = SSL_CTX_set_session_id_context
  #fun ssl_ctx_set_session_cache_mode = SSL_CTX_set_session_cache_mode

  #SSL_CTRL_NEED_TMP_RSA = 1
  #SSL_CTRL_SET_TMP_RSA = 2
  #SSL_CTRL_SET_TMP_DH = 3
  SSL_CTRL_SET_TMP_ECDH = 4
  #SSL_CTRL_SET_TMP_RSA_CB = 5
  #SSL_CTRL_SET_TMP_DH_CB = 6
  #SSL_CTRL_SET_TMP_ECDH_CB = 7

  SSL_CTRL_OPTIONS = 32
  SSL_CTRL_MODE = 33
  SSL_CTRL_CLEAR_OPTIONS = 77
  SSL_CTRL_CLEAR_MODE = 78

  SSL_OP_ALL = 0x80000bff_u32
  SSL_OP_DONT_INSERT_EMPTY_FRAGMENTS = 0x00000800_u32
  SSL_OP_NO_COMPRESSION = 0x00020000_u32
  SSL_OP_NO_SSLv2 = 0x01000000_u32
  SSL_OP_NO_SSLv3 = 0x02000000_u32
  SSL_OP_NO_TLSv1 = 0x04000000_u32
  SSL_OP_NO_TLSv1_2 = 0x08000000_u32
  SSL_OP_NO_TLSv1_1 = 0x10000000_u32
  SSL_OP_NO_SESSION_RESUMPTION_ON_RENEGOTIATION = 0x00010000_u32
  SSL_OP_SINGLE_ECDH_USE = 0x00080000_u32
  SSL_OP_NO_TICKET = 0x00004000_u32
  SSL_OP_CIPHER_SERVER_PREFERENCE = 0x00400000_u32

  OPENSSL_NPN_UNSUPPORTED = 0
  OPENSSL_NPN_NEGOTIATED = 1
  OPENSSL_NPN_NO_OVERLAP = 2

  SSL_TLSEXT_ERR_OK = 0
  SSL_TLSEXT_ERR_ALERT_WARNING = 1
  SSL_TLSEXT_ERR_ALERT_FATAL = 2
  SSL_TLSEXT_ERR_NOACK = 3

  NID_X9_62_prime256v1 = 415
end
