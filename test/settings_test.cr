require "./test_helper"
require "../src/http2"

class HTTP2::SettingsTest < Minitest::Test
  def test_disables_push
    settings = Settings.new
    settings.enable_push = false
    refute settings.enable_push
  end

  def test_to_payload_includes_disabled_push
    settings = Settings.new
    settings.enable_push = false
    assert_equal 1, settings.size
    assert_equal Bytes[0, 2, 0, 0, 0, 0], settings.to_payload
  end

  def test_to_payload_includes_enabled_push
    settings = Settings.new
    settings.enable_push = true
    assert_equal Bytes[0, 2, 0, 0, 0, 1], settings.to_payload
  end
end
