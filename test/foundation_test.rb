# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "base64"
require "openssl"
require_relative "../lib/discussion_bridge_ghost/error"
require_relative "../lib/discussion_bridge_ghost/secret_envelope"
require_relative "../lib/discussion_bridge_ghost/admin_token"
require_relative "../lib/discussion_bridge_ghost/webhook_signature"
require_relative "../lib/discussion_bridge_ghost/native_lock"
require_relative "../lib/discussion_bridge_ghost/wire_json"

class GhostConnectorFoundationTest < Minitest::Test
  UUID = "a4147162-a4ab-4a43-99af-bbbf335189bd"
  OTHER = "20a59dad-638b-4290-a937-1a5fba7efeb1"
  SYNTHETIC_KEY = "a" * 64

  def box(id = UUID, key = SYNTHETIC_KEY)
    DiscussionBridgeGhost::SecretEnvelope.new(application_key: key, installation_id: id)
  end

  def test_authenticated_envelope_round_trip_does_not_contain_secret
    original = { "key" => "SYNTHETIC-private-value", "native" => "文章", "items" => [1, nil, true] }
    encrypted = box.encrypt("configuration", original)
    refute_includes encrypted, original.fetch("key")
    assert_equal original, box.decrypt("configuration", encrypted)
    refute_equal encrypted, box.encrypt("configuration", original)
  end

  def test_installation_purpose_binding_and_application_key_are_independent_boundaries
    encrypted = box.encrypt("journal_request", { "mutation" => "retained", "secret" => "synthetic" }, binding: "operation:one")
    [
      -> { box(OTHER).decrypt("journal_request", encrypted, binding: "operation:one") },
      -> { box.decrypt("journal_response", encrypted, binding: "operation:one") },
      -> { box.decrypt("journal_request", encrypted, binding: "operation:two") },
      -> { box(UUID, "b" * 64).decrypt("journal_request", encrypted, binding: "operation:one") }
    ].each { |read| assert_raises(DiscussionBridgeGhost::Error, &read) }
  end

  def test_ciphertext_corruption_and_open_envelopes_fail_closed
    encrypted = JSON.parse(box.encrypt("configuration", { "secret" => "synthetic" }))
    cipher = Base64.strict_decode64(encrypted.fetch("ciphertext"))
    cipher.setbyte(0, cipher.getbyte(0) ^ 1)
    encrypted["ciphertext"] = Base64.strict_encode64(cipher)
    error = assert_raises(DiscussionBridgeGhost::Error) { box.decrypt("configuration", JSON.generate(encrypted)) }
    assert_equal "secret_unavailable", error.code
    encrypted["ignored"] = "not allowed"
    assert_raises(DiscussionBridgeGhost::Error) { box.decrypt("configuration", JSON.generate(encrypted)) }
  end

  def test_admin_token_matches_ghost_hmac_and_five_minute_lifetime
    api_key = "a" * 24 + ":" + "12" * 32
    encoded = DiscussionBridgeGhost::AdminToken.generate(api_key, now: 1_800_000_000)
    header, payload, signature = encoded.split(".")
    assert_equal({ "alg" => "HS256", "typ" => "JWT", "kid" => "a" * 24 }, JSON.parse(Base64.urlsafe_decode64(header)))
    assert_equal({ "iat" => 1_800_000_000, "exp" => 1_800_000_300, "aud" => "/admin/" }, JSON.parse(Base64.urlsafe_decode64(payload)))
    assert_equal OpenSSL::HMAC.digest("SHA256", ["12" * 32].pack("H*"), "#{header}.#{payload}"), Base64.urlsafe_decode64(signature)
    refute_includes encoded, api_key
    assert_raises(DiscussionBridgeGhost::Error) { DiscussionBridgeGhost::AdminToken.generate("arbitrary") }
  end

  def signature(body, time, secret)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body + time.to_s)}, t=#{time}"
  end

  def test_native_webhook_authenticates_raw_bytes_and_time_not_reencoded_json
    raw = "{\"post\": {\"id\":\"native\"}}"
    now = 1_800_000_000_000
    secret = "SYNTHETIC-webhook-secret-1234567890"
    signed = signature(raw, now, secret)
    assert DiscussionBridgeGhost::WebhookSignature.valid?(header: signed, raw_body: raw, secret: secret, now_ms: now)
    refute DiscussionBridgeGhost::WebhookSignature.valid?(header: signed, raw_body: JSON.generate(JSON.parse(raw)), secret: secret, now_ms: now)
    refute DiscussionBridgeGhost::WebhookSignature.valid?(header: signed, raw_body: raw, secret: secret, now_ms: now + 300_001)
    refute DiscussionBridgeGhost::WebhookSignature.valid?(header: signed, raw_body: raw, secret: "b" * 32, now_ms: now)
    refute DiscussionBridgeGhost::WebhookSignature.valid?(header: signed + ", ignored=1", raw_body: raw, secret: secret, now_ms: now)
  end

  def test_native_writer_key_is_stable_scoped_and_signed_64_bit
    key = DiscussionBridgeGhost::NativeLock.key(UUID)
    assert_equal key, DiscussionBridgeGhost::NativeLock.key(UUID)
    refute_equal key, DiscussionBridgeGhost::NativeLock.key(OTHER)
    assert_operator key, :>=, -(1 << 63)
    assert_operator key, :<, (1 << 63)
    assert_raises(DiscussionBridgeGhost::Error) { DiscussionBridgeGhost::NativeLock.key("1); DROP TABLE installations") }
  end

  def test_error_never_uses_upstream_exception_text
    error = DiscussionBridgeGhost::Error.new("secret=SYNTHETIC-must-not-appear")
    assert_equal "response_invalid", error.code
    refute_includes error.message, "SYNTHETIC"
  end

  def parse_wire(text, maximum = 262_144)
    DiscussionBridgeGhost::WireJson.parse(text, maximum_bytes: maximum)
  end

  def test_response_budget_is_not_the_request_budget
    text = JSON.generate("content" => "x" * 100_000, "counter" => 1)
    assert_equal 100_000, parse_wire(text).fetch("content").bytesize
    assert_raises(DiscussionBridgeGhost::Error) { parse_wire(text, 65_536) }
    assert_raises(DiscussionBridgeGhost::Error) { parse_wire(text, text.bytesize - 1) }
  end

  def test_wire_numbers_are_exact_before_float_rounding
    parsed = parse_wire('{"a": [1.00, 10e-1, 0e99999999], "b": 9007199254740991}')
    assert_equal({ "a" => [1, 1, 0], "b" => 9_007_199_254_740_991 }, parsed)
    ["-0", "-0.0", "-1", "1.00000000000000000000001", "1e-9999", "9007199254740991.1", "9007199254740992", "1e9999999"].each do |token|
      assert_raises(DiscussionBridgeGhost::Error, token) { parse_wire("{\"number\":#{token}}") }
    end
  end

  def test_wire_rejects_duplicates_invalid_utf8_bom_and_invalid_syntax
    ['{"a":1,"a":2}', '{"nested":{"a":1,"a":2}}', "\uFEFF{}", '{"a":NaN}', "{", "\xFF".b].each do |bytes|
      assert_raises(DiscussionBridgeGhost::Error) { parse_wire(bytes) }
    end
  end

  def test_numeric_looking_string_bytes_are_not_reinterpreted
    text = JSON.generate("value" => "1.0000000001 -0 1e999999999", "other" => '"123', "counter" => 20)
      .sub('"counter":20', '"counter":2e1')
    assert_equal({ "value" => "1.0000000001 -0 1e999999999", "other" => '"123', "counter" => 20 }, parse_wire(text))
  end
end
