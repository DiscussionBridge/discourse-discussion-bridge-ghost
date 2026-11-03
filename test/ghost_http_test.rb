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

  def transport(incoming, guard: -> {}, key: KEY, deadline_seconds: 10)
    @connection = Connection.new(incoming)
    DiscussionBridgeGhost::GhostHttp.new(
      origin: "https://ghost.example",
      protocol: OriginRules.new,
      api_key: key,
      guard: guard,
      now: -> { 1_800_000_000 },
      deadline_seconds: deadline_seconds,
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

  def dispatch_identity
    {
      "command_id" => RESOURCE,
      "attempt_id" => "20a59dad-638b-4290-a937-1a5fba7efeb1",
      "execution_id" => "73aa9272-2015-4a17-a5d2-b519dc287872"
    }
  end

  def dispatch_write(
    http,
    dispatch = dispatch_identity,
    body = '{"posts":[{"status":"draft"}]}'
  )
    http.request(
      "POST",
      "/ghost/api/admin/posts/",
      maximum_bytes: 1000,
      authenticated: true,
      allowed_statuses: [201],
      retained_body: body,
      dispatch: dispatch
    )
  end

  def test_denied_guard_has_genuine_no_send_provenance_but_no_native_success_claim
    http =
      transport(
        Incoming.new(201),
        guard: -> { raise DiscussionBridgeGhost::Error.new("disabled") }
      )
    error = assert_raises(DiscussionBridgeGhost::Error) { dispatch_write(http) }
    evidence = http.actual_dispatch_evidence(error, dispatch: dispatch_identity)
    assert_equal "not_sent", evidence.value.fetch("phase")
    assert_equal "POST", evidence.value.fetch("method")
    assert_equal "/ghost/api/admin/posts/", evidence.value.fetch("path")
    assert_nil evidence.response
    assert_empty @connection.requests
    refute evidence.value.key?("applied")
    refute evidence.value.key?("native_id")
  end

  def test_setup_failure_before_request_is_no_send_but_entered_request_failure_is_uncertain
    http = transport(Incoming.new(201))
    @connection.define_singleton_method(:start) do
      raise "SYNTHETIC-private-setup-failure"
    end
    error =
      assert_raises(DiscussionBridgeGhost::GhostHttp::Failure) do
        dispatch_write(http)
      end
    assert_equal "not_sent",
                 http
                   .actual_dispatch_evidence(error, dispatch: dispatch_identity)
                   .value
                   .fetch("phase")
    assert_empty @connection.requests
    http = transport(:failure)
    error =
      assert_raises(DiscussionBridgeGhost::GhostHttp::Failure) do
        dispatch_write(http)
      end
    assert_equal "may_have_sent",
                 http
                   .actual_dispatch_evidence(error, dispatch: dispatch_identity)
                   .value
                   .fetch("phase")
    assert_equal 1, @connection.requests.length
    assert_nil error.cause
  end

  def test_dispatch_proof_cannot_be_forged_transferred_or_rebound_to_another_attempt
    http =
      transport(
        Incoming.new(201),
        guard: -> { raise DiscussionBridgeGhost::Error.new("disabled") }
      )
    error = assert_raises(DiscussionBridgeGhost::Error) { dispatch_write(http) }
    assert_nil http.actual_dispatch_evidence(
                 DiscussionBridgeGhost::Error.new("disabled"),
                 dispatch: dispatch_identity
               )
    assert_nil http.actual_dispatch_evidence(
                 error.dup,
                 dispatch: dispatch_identity
               )
    %w[command_id attempt_id execution_id].each do |field|
      other =
        dispatch_identity.merge(field => "af4e91f3-6331-4adf-8da1-5ecde1d56aff")
      assert_nil http.actual_dispatch_evidence(error, dispatch: other)
    end
    unrelated = transport(Incoming.new(201))
    assert_nil unrelated.actual_dispatch_evidence(
                 error,
                 dispatch: dispatch_identity
               )
    fabricated =
      DiscussionBridgeGhost::GhostHttp::DispatchEvidence.new(
        value: {
        },
        response: nil
      )
    assert_nil http.actual_dispatch_evidence(
                 fabricated,
                 dispatch: dispatch_identity
               )
  end

  def test_payload_and_attempt_identity_are_snapshotted_before_mutable_guard_callbacks
    body = '{"posts":[{"status":"draft"}]}'.dup
    expected_body = body.dup
    identity = dispatch_identity
    expected_identity = identity.dup
    http =
      transport(
        Incoming.new(201),
        guard: -> do
          body.replace("SYNTHETIC-mutated-after-preparation")
          identity["attempt_id"] = "af4e91f3-6331-4adf-8da1-5ecde1d56aff"
        end
      )
    result = dispatch_write(http, identity, body)
    evidence =
      http.actual_dispatch_evidence(result, dispatch: expected_identity)
    assert_equal expected_body, @connection.requests.first.body
    assert_equal Digest::SHA256.hexdigest(expected_body),
                 evidence.value.fetch("body_sha256")
    assert_equal "response_received", evidence.value.fetch("phase")
    assert_nil http.actual_dispatch_evidence(result, dispatch: identity)
    assert_raises(FrozenError) do
      evidence.value.fetch("dispatch")["attempt_id"] = "changed"
    end
  end

  def test_completed_response_is_retained_even_when_the_post_call_guard_revokes_authority
    guards = 0
    http =
      transport(
        Incoming.new(201, "SYNTHETIC-private-native-response"),
        guard: -> do
          guards += 1
          raise DiscussionBridgeGhost::Error.new("disabled") if guards == 2
        end
      )
    error = assert_raises(DiscussionBridgeGhost::Error) { dispatch_write(http) }
    evidence = http.actual_dispatch_evidence(error, dispatch: dispatch_identity)
    assert_equal "response_received", evidence.value.fetch("phase")
    assert_equal "SYNTHETIC-private-native-response", evidence.response.bytes
    refute_includes evidence.inspect, "private-native-response"
    refute_includes JSON.generate(evidence.value), KEY
    assert @connection.closed
  end

  def test_429_and_invalid_reply_after_request_entry_are_not_no_send
    [
      Incoming.new(429, "", "retry-after" => "15"),
      Incoming.new(201, "{}", "content-length" => "9001")
    ].each do |incoming|
      http = transport(incoming)
      error =
        assert_raises(DiscussionBridgeGhost::GhostHttp::Failure) do
          dispatch_write(http)
        end
      evidence =
        http.actual_dispatch_evidence(error, dispatch: dispatch_identity)
      assert_equal "may_have_sent", evidence.value.fetch("phase")
      assert_nil evidence.response
      assert_equal 1, @connection.requests.length
    end
  end

  def test_dispatch_metadata_is_exact_nullable_and_cannot_claim_provenance_for_generic_payloads
    [
      false,
      {},
      dispatch_identity.merge("unknown" => "extra"),
      dispatch_identity.merge("command_id" => "invalid")
    ].each do |invalid|
      http = transport(Incoming.new(201))
      assert_raises(DiscussionBridgeGhost::Error) do
        dispatch_write(http, invalid)
      end
      assert_empty @connection.requests
    end
    http = transport(Incoming.new(201))
    assert_raises(DiscussionBridgeGhost::Error) do
      http.request(
        "POST",
        "/ghost/api/admin/posts/",
        maximum_bytes: 100,
        authenticated: true,
        payload: {
          "posts" => []
        },
        dispatch: dispatch_identity
      )
    end
    assert_empty @connection.requests
    result = dispatch_write(http, nil)
    assert_nil http.actual_dispatch_evidence(
                 result,
                 dispatch: dispatch_identity
               )
  end

  def test_one_attempt_cannot_enter_request_twice_or_obtain_fresh_no_send_after_dispatch
    http = transport(Incoming.new(201))
    identity = dispatch_identity
    result = dispatch_write(http, identity)
    original = http.actual_dispatch_evidence(result, dispatch: identity)
    assert_equal "response_received", original.value.fetch("phase")
    error =
      assert_raises(DiscussionBridgeGhost::Error) do
        dispatch_write(http, identity.dup)
      end
    assert_nil http.actual_dispatch_evidence(error, dispatch: identity)
    assert_same original,
                http.actual_dispatch_evidence(result, dispatch: identity)
    assert_equal 1, @connection.requests.length
  end

  def with_interruption_at(fragment)
    path =
      File.expand_path("../lib/discussion_bridge_ghost/ghost_http.rb", __dir__)
    line = File.readlines(path).find_index { |value| value.include?(fragment) }
    refute_nil line
    trace =
      TracePoint.new(:line) do |event|
        if event.path == path && event.lineno == line + 1
          trace.disable
          raise Timeout::Error
        end
      end
    trace.enable
    yield
  ensure
    trace&.disable
  end

  def test_interrupted_duplicate_never_creates_no_send_for_the_previous_dispatched_attempt
    http = transport(Incoming.new(201))
    identity = dispatch_identity
    result = dispatch_write(http, identity)
    [
      "@dispatch_mutex.synchronize do",
      "if @dispatches.key?(key)"
    ].each do |line|
      error =
        assert_raises(DiscussionBridgeGhost::Error) do
          with_interruption_at(line) { dispatch_write(http, identity) }
        end
      assert_nil http.actual_dispatch_evidence(error, dispatch: identity)
      assert_equal "response_received",
                   http
                     .actual_dispatch_evidence(result, dispatch: identity)
                     .value
                     .fetch("phase")
    end
    assert_equal 1, @connection.requests.length
  end

  def test_interruption_before_exclusive_registration_is_not_a_dispatch_claim
    [
      "@dispatch_mutex.synchronize do",
      "@dispatches[key] = true",
      "dispatch_claimed = true"
    ].each do |line|
      http = transport(Incoming.new(201))
      error =
        assert_raises(DiscussionBridgeGhost::Error) do
          with_interruption_at(line) { dispatch_write(http) }
        end
      assert_nil http.actual_dispatch_evidence(
                   error,
                   dispatch: dispatch_identity
                 )
      assert_empty @connection.requests
    end
    http = transport(Incoming.new(201))
    error =
      assert_raises(DiscussionBridgeGhost::Error) do
        with_interruption_at("@guard.call") { dispatch_write(http) }
      end
    assert_equal "not_sent",
                 http
                   .actual_dispatch_evidence(error, dispatch: dispatch_identity)
                   .value
                   .fetch("phase")
    assert_empty @connection.requests
  end

  def test_two_concurrent_invocations_of_one_attempt_cannot_both_send
    http = transport(Incoming.new(201))
    gate = Queue.new
    threads =
      2.times.map do
        Thread.new do
          gate.pop
          begin
            dispatch_write(http)
          rescue DiscussionBridgeGhost::Error => error
            error
          end
        end
      end
    2.times { gate << true }
    threads.each do |thread|
      assert thread.join(2), "request thread must terminate"
    end
    outcomes = threads.map(&:value)
    assert_equal 1,
                 outcomes.count { |outcome|
                   outcome.is_a?(DiscussionBridgeGhost::GhostHttp::Response)
                 }
    failure =
      outcomes.find { |outcome| outcome.is_a?(DiscussionBridgeGhost::Error) }
    assert_nil http.actual_dispatch_evidence(
                 failure,
                 dispatch: dispatch_identity
               )
    assert_equal 1, @connection.requests.length
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  def test_proof_remains_identity_bound_and_live_while_response_or_error_is_held
    %w[response_received not_sent may_have_sent].each do |phase|
      incoming = phase == "may_have_sent" ? :failure : Incoming.new(201)
      guard =
        phase == "not_sent" ?
          -> { raise DiscussionBridgeGhost::Error.new("disabled").freeze } :
          -> {}
      http = transport(incoming, guard: guard)
      outcome =
        begin
          dispatch_write(http)
        rescue DiscussionBridgeGhost::Error => error
          error
        end
      assert !http.actual_dispatch_evidence(
               outcome,
               dispatch: dispatch_identity
             ).nil?
      3.times { GC.start(full_mark: true, immediate_sweep: true) }
      evidence =
        http.actual_dispatch_evidence(outcome, dispatch: dispatch_identity)
      refute_nil evidence
      assert_equal phase, evidence.value.fetch("phase")
      assert_nil http.actual_dispatch_evidence(
                   outcome.dup,
                   dispatch: dispatch_identity
                 )
      assert_nil http.actual_dispatch_evidence(
                   outcome,
                   dispatch: dispatch_identity.merge("attempt_id" => RESOURCE)
                 )
      other = transport(Incoming.new(201))
      assert_nil other.actual_dispatch_evidence(
                   outcome,
                   dispatch: dispatch_identity
                 )
    end
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
      Incoming.new(200, "{}", "content-length" => "10"),
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

  class SlowBody < Incoming
    attr_reader :entered_body

    def read_body
      @entered_body = true
      sleep 0.2
      yield "{}"
    end
  end

  def test_one_deadline_covers_body_reading_and_closes_the_connection
    incoming = SlowBody.new
    http = transport(incoming, deadline_seconds: 0.02)
    error =
      assert_raises(DiscussionBridgeGhost::GhostHttp::Failure) do
        http.request(
          "GET",
          "/ghost/api/admin/posts/",
          maximum_bytes: 100,
          authenticated: true
        )
      end
    assert incoming.entered_body
    assert @connection.closed
    assert_nil error.cause
  end

  def test_native_mutation_can_send_its_retained_exact_body_bytes
    raw = " {\"posts\": [] }\n"
    http = transport(Incoming.new)
    http.request(
      "POST",
      "/ghost/api/admin/posts/",
      maximum_bytes: 100,
      authenticated: true,
      retained_body: raw
    )
    assert_equal raw.b, @connection.requests.first.body.b
    assert_raises(DiscussionBridgeGhost::Error) do
      http.request(
        "POST",
        "/ghost/api/admin/posts/",
        maximum_bytes: 100,
        authenticated: true,
        retained_body: raw,
        payload: {
        }
      )
    end
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
      '{"posts":[{"id":"1234567890abcdef12345678","metric":1e999}]}',
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

  def test_deadline_traverses_standard_error_connection_setup_cleanup
    http = transport(Incoming.new, deadline_seconds: 0.02)
    setup_closed = false
    @connection.define_singleton_method(:start) do
      begin
        sleep 0.1
      rescue StandardError
        setup_closed = true
        raise
      end
    end
    error =
      assert_raises(DiscussionBridgeGhost::GhostHttp::Failure) do
        http.request(
          "GET",
          "/ghost/api/admin/posts/",
          maximum_bytes: 100,
          authenticated: true
        )
      end
    assert setup_closed, "Cancellation must reach pre-session socket cleanup"
    assert_nil error.cause
    assert_empty @connection.requests
  end

  def catalog(kind, payload)
    DiscussionBridgeGhost::GhostAdminClient.new(
      http: ReadTransport.new { |_path| JSON.generate(payload) }
    ).catalog_page(kind, page: 1)
  end

  def test_catalog_rejects_missing_or_non_object_metadata_and_pagination
    [nil, "private scalar", [], 3, true].each do |value|
      [
        { "users" => [], "meta" => value },
        { "users" => [], "meta" => { "pagination" => value } }
      ].each do |payload|
        error =
          assert_raises(DiscussionBridgeGhost::Error) do
            catalog("authors", payload)
          end
        assert_equal "response_invalid", error.code
      end
    end
    error =
      assert_raises(DiscussionBridgeGhost::Error) do
        catalog("authors", { "users" => [] })
      end
    assert_equal "response_invalid", error.code
    error =
      assert_raises(DiscussionBridgeGhost::Error) do
        catalog("authors", { "users" => [], "meta" => {} })
      end
    assert_equal "response_invalid", error.code
  end

  def test_catalog_validates_selected_scalars_and_projects_only_pagination_facts
    %w[authors taxonomy].each do |kind|
      resource, selected = kind == "authors" ? %w[users status] : %w[tags slug]
      pagination = {
        "page" => 1,
        "total" => 1,
        "next" => nil,
        "private" => {
          "email" => "SYNTHETIC-private"
        }
      }
      item = { "id" => ID, "name" => "Native label" }
      payload = { resource => [item], "meta" => { "pagination" => pagination } }
      # Missing native optional fields stay missing; availability is decided by
      # the coordinator, never inferred from an invented default here.
      result = catalog(kind, payload)
      assert_equal %w[id name], result.fetch("items").first.keys.sort
      assert_equal %w[next page total], result.fetch("pagination").keys.sort
      refute_includes JSON.generate(result), "SYNTHETIC-private"
      [nil, {}, [], 1, false].each do |bad|
        item[selected] = bad
        error =
          assert_raises(DiscussionBridgeGhost::Error) { catalog(kind, payload) }
        assert_equal "response_invalid", error.code
      end
      item[selected] = kind == "authors" ? "active" : "native-label"
      assert_equal item[selected],
                   catalog(kind, payload).fetch("items").first.fetch(selected)
    end
  end
end
