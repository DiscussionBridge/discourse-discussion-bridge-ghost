# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "base64"
require "openssl"
require "pp"
require_relative "../lib/discussion_bridge_ghost/error"
require_relative "../lib/discussion_bridge_ghost/protected_diagnostics"
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
    DiscussionBridgeGhost::SecretEnvelope.new(
      application_key: key,
      installation_id: id
    )
  end

  def test_authenticated_envelope_round_trip_does_not_contain_secret
    original = {
      "key" => "SYNTHETIC-private-value",
      "native" => "文章",
      "items" => [1, nil, true]
    }
    encrypted = box.encrypt("configuration", original)
    refute_includes encrypted, original.fetch("key")
    assert_equal original, box.decrypt("configuration", encrypted)
    refute_equal encrypted, box.encrypt("configuration", original)
  end

  def test_installation_purpose_binding_and_application_key_are_independent_boundaries
    encrypted =
      box.encrypt(
        "journal_request",
        { "mutation" => "retained", "secret" => "synthetic" },
        binding: "operation:one"
      )
    [
      -> do
        box(OTHER).decrypt(
          "journal_request",
          encrypted,
          binding: "operation:one"
        )
      end,
      -> do
        box.decrypt("journal_response", encrypted, binding: "operation:one")
      end,
      -> do
        box.decrypt("journal_request", encrypted, binding: "operation:two")
      end,
      -> do
        box(UUID, "b" * 64).decrypt(
          "journal_request",
          encrypted,
          binding: "operation:one"
        )
      end
    ].each { |read| assert_raises(DiscussionBridgeGhost::Error, &read) }
  end

  def test_ciphertext_corruption_and_open_envelopes_fail_closed
    encrypted =
      JSON.parse(box.encrypt("configuration", { "secret" => "synthetic" }))
    cipher = Base64.strict_decode64(encrypted.fetch("ciphertext"))
    cipher.setbyte(0, cipher.getbyte(0) ^ 1)
    encrypted["ciphertext"] = Base64.strict_encode64(cipher)
    error =
      assert_raises(DiscussionBridgeGhost::Error) do
        box.decrypt("configuration", JSON.generate(encrypted))
      end
    assert_equal "secret_unavailable", error.code
    encrypted["ignored"] = "not allowed"
    assert_raises(DiscussionBridgeGhost::Error) do
      box.decrypt("configuration", JSON.generate(encrypted))
    end
  end

  def test_protected_objects_do_not_inspect_or_serialize_key_material
    envelope = box
    derived = envelope.instance_variable_get(:@key)
    [
      envelope.inspect,
      envelope.to_s,
      PP.pp(envelope, +""),
      JSON.generate(envelope)
    ].each do |text|
      refute_includes text.b, SYNTHETIC_KEY.b
      refute_includes text.b, derived.b
      refute_includes text, "@key="
    end
    value = { "secret" => "SYNTHETIC-plaintext" }
    assert_equal value,
                 envelope.decrypt(
                   "configuration",
                   envelope.encrypt("configuration", value)
                 )
  end

  def test_admin_token_matches_ghost_hmac_and_five_minute_lifetime
    api_key = "a" * 24 + ":" + "12" * 32
    encoded =
      DiscussionBridgeGhost::AdminToken.generate(api_key, now: 1_800_000_000)
    header, payload, signature = encoded.split(".")
    assert_equal(
      { "alg" => "HS256", "typ" => "JWT", "kid" => "a" * 24 },
      JSON.parse(Base64.urlsafe_decode64(header))
    )
    assert_equal(
      { "iat" => 1_800_000_000, "exp" => 1_800_000_300, "aud" => "/admin/" },
      JSON.parse(Base64.urlsafe_decode64(payload))
    )
    assert_equal OpenSSL::HMAC.digest(
                   "SHA256",
                   ["12" * 32].pack("H*"),
                   "#{header}.#{payload}"
                 ),
                 Base64.urlsafe_decode64(signature)
    refute_includes encoded, api_key
    assert_raises(DiscussionBridgeGhost::Error) do
      DiscussionBridgeGhost::AdminToken.generate("arbitrary")
    end
  end

  def signature(body, time, secret)
    "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body + time.to_s)}, t=#{time}"
  end

  def test_native_webhook_authenticates_raw_bytes_and_time_not_reencoded_json
    raw = "{\"post\": {\"id\":\"native\"}}"
    now = 1_800_000_000_000
    secret = "SYNTHETIC-webhook-secret-1234567890"
    signed = signature(raw, now, secret)
    assert DiscussionBridgeGhost::WebhookSignature.valid?(
             header: signed,
             raw_body: raw,
             secret: secret,
             now_ms: now
           )
    refute DiscussionBridgeGhost::WebhookSignature.valid?(
             header: signed,
             raw_body: JSON.generate(JSON.parse(raw)),
             secret: secret,
             now_ms: now
           )
    refute DiscussionBridgeGhost::WebhookSignature.valid?(
             header: signed,
             raw_body: raw,
             secret: secret,
             now_ms: now + 300_001
           )
    refute DiscussionBridgeGhost::WebhookSignature.valid?(
             header: signed,
             raw_body: raw,
             secret: "b" * 32,
             now_ms: now
           )
    refute DiscussionBridgeGhost::WebhookSignature.valid?(
             header: signed + ", ignored=1",
             raw_body: raw,
             secret: secret,
             now_ms: now
           )
  end

  def test_native_writer_key_is_stable_scoped_and_signed_64_bit
    key = DiscussionBridgeGhost::NativeLock.key(UUID)
    assert_equal key, DiscussionBridgeGhost::NativeLock.key(UUID)
    refute_equal key, DiscussionBridgeGhost::NativeLock.key(OTHER)
    assert_operator key, :>=, -(1 << 63)
    assert_operator key, :<, (1 << 63)
    assert_raises(DiscussionBridgeGhost::Error) do
      DiscussionBridgeGhost::NativeLock.key("1); DROP TABLE installations")
    end
  end

  class LockConnection
    attr_accessor :held, :fail_acquire, :fail_cleanup
    attr_reader :disconnected

    def initialize
      @session = Object.new
      @held = false
    end

    def adapter_name
      "PostgreSQL"
    end

    def raw_connection
      @session
    end

    def uncached
      yield
    end

    def select_value(sql)
      if sql.include?("pg_try_advisory_lock")
        @held = true
        raise "synthetic lost acquisition reply" if fail_acquire
        true
      elsif sql.include?("pg_advisory_unlock")
        raise "synthetic cleanup failure" if fail_cleanup
        @held = false
        true
      elsif sql.include?("EXISTS")
        @held
      else
        12_345
      end
    end

    def disconnect!
      @disconnected = true
      @held = false
    end
  end

  class LockPool
    attr_reader :connection, :checkins, :removals

    def initialize
      @connection = LockConnection.new
      @checkins = []
      @removals = []
    end

    def checkout
      @connection
    end

    def checkin(connection)
      @checkins << connection.held
    end

    def remove(connection)
      @removals << connection
    end
  end

  def test_unknown_lock_acquisition_discards_its_exact_session
    pool = LockPool.new
    pool.connection.fail_acquire = true
    assert_raises(RuntimeError) do
      DiscussionBridgeGhost::NativeLock.synchronize(UUID, pool: pool) {}
    end
    assert_empty pool.checkins
    assert_equal [pool.connection], pool.removals
    assert pool.connection.disconnected
    refute pool.connection.held
  end

  def test_failed_cleanup_discards_session_and_expired_lease_never_revalidates
    pool = LockPool.new
    previous = nil
    DiscussionBridgeGhost::NativeLock.synchronize(UUID, pool: pool) do |lease|
      previous = lease
    end
    DiscussionBridgeGhost::NativeLock.synchronize(UUID, pool: pool) do |lease|
      assert lease.assert!
      assert_raises(DiscussionBridgeGhost::Error) { previous.assert! }
      pool.connection.fail_cleanup = true
    end
    assert_equal [false], pool.checkins
    assert pool.connection.disconnected
    assert_raises(DiscussionBridgeGhost::Error) { previous.assert! }
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
    assert_raises(DiscussionBridgeGhost::Error) do
      parse_wire(text, text.bytesize - 1)
    end
  end

  def test_wire_numbers_are_exact_before_float_rounding
    parsed =
      parse_wire('{"a": [1.00, 10e-1, 0e99999999], "b": 9007199254740991}')
    assert_equal({ "a" => [1, 1, 0], "b" => 9_007_199_254_740_991 }, parsed)
    %w[
      -0
      -0.0
      -1
      1.00000000000000000000001
      1e-9999
      9007199254740991.1
      9007199254740992
      1e9999999
    ].each do |token|
      assert_raises(DiscussionBridgeGhost::Error, token) do
        parse_wire("{\"number\":#{token}}")
      end
    end
  end

  def test_wire_rejects_duplicates_invalid_utf8_bom_and_invalid_syntax
    [
      '{"a":1,"a":2}',
      '{"nested":{"a":1,"a":2}}',
      "\uFEFF{}",
      '{"a":NaN}',
      "{",
      "\xFF".b
    ].each do |bytes|
      assert_raises(DiscussionBridgeGhost::Error) { parse_wire(bytes) }
    end
  end

  def test_numeric_looking_string_bytes_are_not_reinterpreted
    text =
      JSON.generate(
        "value" => "1.0000000001 -0 1e999999999",
        "other" => '"123',
        "counter" => 20
      ).sub('"counter":20', '"counter":2e1')
    assert_equal(
      {
        "value" => "1.0000000001 -0 1e999999999",
        "other" => '"123',
        "counter" => 20
      },
      parse_wire(text)
    )
  end
end
