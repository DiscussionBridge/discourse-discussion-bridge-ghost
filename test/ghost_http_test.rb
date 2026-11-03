# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "ostruct"
require_relative "../lib/discussion_bridge_ghost/error"
require_relative "../lib/discussion_bridge_ghost/protected_diagnostics"
require_relative "../lib/discussion_bridge_ghost/admin_token"
require_relative "../lib/discussion_bridge_ghost/secret_envelope"
require_relative "../lib/discussion_bridge_ghost/wire_json"
require_relative "../lib/discussion_bridge_ghost/wire_protocol"
require_relative "../lib/discussion_bridge_ghost/ghost_http"
require_relative "../lib/discussion_bridge_ghost/ghost_admin_client"

class GhostNativeHttpTest < Minitest::Test
  KEY = "a" * 24 + ":" + "12" * 32
  ID = "1234567890abcdef12345678"
  OTHER_ID = "abcdef1234567890abcdef12"
  RESOURCE = "a4147162-a4ab-4a43-99af-bbbf335189bd"

  class OriginRules
    def origin_key(value)
      unless value == "https://ghost.example"
        raise DiscussionBridgeGhost::Error.new("configuration_invalid")
      end
      value
    end
  end

  class Incoming
    attr_reader :code

    def initialize(code = 200, bytes = "{}", headers = {})
      @code = code.to_s
      @bytes = bytes
      @headers = { "content-type" => "application/json; charset=utf-8" }.merge(
        headers
      )
    end

    def [](name)
      @headers[name.downcase]
    end

    def read_body
      @bytes.each { |part| yield part } if @bytes.is_a?(Array)
      yield @bytes unless @bytes.is_a?(Array)
    end
  end

  class Connection
    attr_accessor :use_ssl,
                  :verify_mode,
                  :open_timeout,
                  :read_timeout,
                  :write_timeout,
                  :max_retries
    attr_reader :requests, :closed

    def initialize(incoming)
      @incoming = incoming
      @requests = []
    end

    def start
      yield self
    ensure
      @closed = true
    end

    def request(outgoing)
      @requests << outgoing
      raise "SYNTHETIC-private-upstream-exception" if @incoming == :failure
      yield @incoming
    end
  end

  def transport(incoming, guard: -> {}, key: KEY)
    @connection = Connection.new(incoming)
    DiscussionBridgeGhost::GhostHttp.new(
      origin: "https://ghost.example",
      protocol: OriginRules.new,
      api_key: key,
      guard: guard,
      now: -> { 1_800_000_000 },
      factory: ->(host, port) do
        assert_equal ["ghost.example", 443], [host, port]
        @connection
      end
    )
  end

  def test_private_api_uses_tls_private_jwt_and_current_authority_without_retries
    guards = 0
    http = transport(Incoming.new, guard: -> { guards += 1 })
    result =
      http.request(
        "GET",
        "/ghost/api/admin/posts/",
        maximum_bytes: 100,
        authenticated: true
      )
    request = @connection.requests.fetch(0)
    assert_equal 200, result.status
    assert_equal 2, guards
    assert request["authorization"].start_with?("Ghost ")
    assert_nil request["cookie"]
    assert_equal "identity", request["accept-encoding"]
    assert_equal true, @connection.use_ssl
    assert_equal OpenSSL::SSL::VERIFY_PEER, @connection.verify_mode
    assert_equal 0, @connection.max_retries
    assert @connection.closed
    refute_includes http.inspect, KEY
  end

  def test_public_verification_never_sends_private_credentials
    http =
      transport(
        Incoming.new(200, "<html></html>", "content-type" => "text/html")
      )
    http.request("GET", "/article/", maximum_bytes: 100, media: "html")
    assert_nil @connection.requests.first["authorization"]
    assert_nil @connection.requests.first["cookie"]
  end

  def test_redirects_are_not_followed_and_429_retains_only_safe_cooldown
    http =
      transport(Incoming.new(302, "", "location" => "https://foreign.example/"))
    error =
      assert_raises(DiscussionBridgeGhost::GhostHttp::Failure) do
        http.request(
          "GET",
          "/ghost/api/admin/posts/",
          maximum_bytes: 100,
          authenticated: true
        )
      end
    assert_equal 302, error.status
    assert_equal 1, @connection.requests.length
    http =
      transport(
        Incoming.new(429, "private upstream error", "retry-after" => "15")
      )
    error =
      assert_raises(DiscussionBridgeGhost::GhostHttp::Failure) do
        http.request(
          "GET",
          "/ghost/api/admin/posts/",
          maximum_bytes: 100,
          authenticated: true
        )
      end
    assert_equal 15, error.retry_after_seconds
    refute_includes error.message, "private upstream"
  end

  def test_declared_and_streaming_budgets_bad_media_and_encoding_fail_closed
    [
      Incoming.new(200, "{}", "content-length" => "101"),
      Incoming.new(200, ["a" * 60, "b" * 60]),
      Incoming.new(200, "{}", "content-type" => "text/html"),
      Incoming.new(200, "{}", "content-encoding" => "gzip")
    ].each do |incoming|
      http = transport(incoming)
      assert_raises(DiscussionBridgeGhost::GhostHttp::Failure) do
        http.request(
          "GET",
          "/ghost/api/admin/posts/",
          maximum_bytes: 100,
          authenticated: true
        )
      end
      assert @connection.closed
    end
  end

  def test_auth_does_not_escape_api_path_and_no_effect_precedes_failed_guard
    http = transport(Incoming.new)
    %w[
      //foreign.example/
      /article/
      /ghost/api/admin/posts/../settings/
      /ghost/api/admin/%2e%2e/settings/
    ].each do |path|
      assert_raises(DiscussionBridgeGhost::Error) do
        http.request("GET", path, maximum_bytes: 100, authenticated: true)
      end
    end
    assert_empty @connection.requests
    http =
      transport(
        Incoming.new,
        guard: -> { raise DiscussionBridgeGhost::Error.new("disabled") }
      )
    assert_raises(DiscussionBridgeGhost::Error) do
      http.request(
        "GET",
        "/ghost/api/admin/posts/",
        maximum_bytes: 100,
        authenticated: true
      )
    end
    assert_empty @connection.requests
  end

  def test_unknown_transport_failures_drop_exception_details_and_cause
    http = transport(:failure)
    error =
      assert_raises(DiscussionBridgeGhost::GhostHttp::Failure) do
        http.request(
          "POST",
          "/ghost/api/admin/posts/",
          maximum_bytes: 100,
          authenticated: true,
          payload: {
            "posts" => []
          }
        )
      end
    refute_includes error.message, "SYNTHETIC"
    assert_nil error.cause
    assert_equal 1, @connection.requests.length
    assert @connection.closed
  end

  class ReadTransport
    attr_reader :paths

    def initialize(&reply)
      @reply = reply
      @paths = []
    end

    def request(method, path, **options)
      unless method == "GET" && options[:authenticated] == true
        raise "private API contract"
      end
      @paths << path
      OpenStruct.new(bytes: @reply.call(path))
    end
  end

  def test_native_lookup_distinguishes_posts_pages_and_checks_both_before_create
    transport =
      ReadTransport.new do |path|
        kind = path.include?("/posts/") ? "posts" : "pages"
        JSON.generate(
          kind => [
            {
              "id" => kind == "posts" ? ID : OTHER_ID,
              "slug" => "article",
              "metric" => 1.5
            }
          ]
        )
      end
    client = DiscussionBridgeGhost::GhostAdminClient.new(http: transport)
    matches = client.find_by_resource(RESOURCE)
    assert_equal %w[post page], matches.map { |item| item.fetch("type") }
    assert_equal 2, transport.paths.length
    assert_includes transport.paths.first, "hash-discussionbridge-resource-"
    assert_equal 1.5, matches.first.fetch("metric")
  end

  def test_native_reader_rejects_type_identity_duplicate_json_and_invalid_utf8
    [
      JSON.generate("posts" => [{ "id" => OTHER_ID }]),
      JSON.generate("posts" => [{ "id" => ID, "type" => "page" }]),
      '{"posts":[],"posts":[]}',
      "{\"posts\":[\"\xff\"]}".b
    ].each do |raw|
      client =
        DiscussionBridgeGhost::GhostAdminClient.new(
          http: ReadTransport.new { |_path| raw }
        )
      assert_raises(DiscussionBridgeGhost::Error) { client.get(ID) }
    end
  end

  def test_catalog_page_is_bounded_and_does_not_forward_extra_private_user_fields
    transport =
      ReadTransport.new do |_path|
        JSON.generate(
          "users" => [
            {
              "id" => ID,
              "name" => "Author",
              "status" => "active",
              "email" => "SYNTHETIC-private@example.invalid"
            }
          ],
          "meta" => {
            "pagination" => {
              "page" => 1,
              "next" => nil,
              "total" => 1
            }
          }
        )
      end
    value =
      DiscussionBridgeGhost::GhostAdminClient.new(http: transport).catalog_page(
        "authors",
        page: 1
      )
    assert_equal %w[id name status], value.fetch("items").first.keys.sort
    refute_includes JSON.generate(value), "private@example"
  end
end
