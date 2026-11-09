# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/discussion_bridge_ghost/ghost_site"
require_relative "../lib/discussion_bridge_ghost/publication"

class PublicationRecoveryTest < Minitest::Test
  Error = DiscussionBridgeGhost::Error
  URL = "https://ghost.example.test/article/"

  def setup
    @publisher = DiscussionBridgeGhost::Publication.allocate
    @publisher.instance_variable_set(:@kind, "post")
    @publisher.instance_variable_set(:@state, { "native_id" => "native-1", "url" => URL })
    @publisher.instance_variable_set(:@mapping, { "mapping_state" => "pending" })
    @publisher.define_singleton_method(:save!) {}
    @publisher.define_singleton_method(:assert_owned!) { |article| raise Error.new("native_ownership_conflict") if article["id"] != "native-1" }
    @publisher.define_singleton_method(:fragment_digest) { |html, source_url:| Digest::SHA256.hexdigest("#{source_url}:#{html}") }
  end

  def test_superseded_publish_readback_becomes_baseline_without_another_write
    article = owned_article
    stub_article(article)
    operation = {
      "publish_started" => true, "html" => article.fetch("html"), "title" => article.fetch("title"),
      "source_url" => "https://discourse.example.test/t/1", "revision" => "superseded-revision",
    }

    @publisher.send(:reconcile_prior!, operation, nil)

    baseline = @publisher.send(:native_baseline)
    assert_equal "superseded-revision", baseline.fetch("revision")
    assert_equal "published", baseline.fetch("status")
    assert_equal article.fetch("updated_at"), baseline.fetch("native_revision")
  end

  def test_superseded_publish_without_a_native_write_keeps_exact_older_baseline
    article = owned_article
    stub_article(article)
    url = "https://discourse.example.test/t/1"
    digest = @publisher.send(:fragment_digest, article.fetch("html"), source_url: url)
    @publisher.send(:remember_native!, article, source_url: url, digest: digest, revision: "old-revision")

    @publisher.send(:reconcile_prior!, {
      "publish_started" => true, "html" => "not written", "title" => "New title",
      "source_url" => url, "revision" => "superseded-revision",
    }, nil)

    assert_equal "old-revision", @publisher.send(:native_baseline).fetch("revision")
  end

  def test_foreign_result_cannot_become_a_baseline
    stub_article(owned_article.merge("id" => "foreign"))

    error = assert_raises(Error) do
      @publisher.send(:reconcile_prior!, { "publish_started" => true }, nil)
    end
    assert_equal "native_ownership_conflict", error.code
  end

  def test_moved_topic_withdrawal_requires_exact_native_revision_before_lease_renewal_and_write
    article = owned_article
    original = article.fetch("updated_at")
    source_url = "https://discourse.example.test/t/1"
    digest = @publisher.send(:fragment_digest, article.fetch("html"), source_url: source_url)
    @publisher.send(:remember_native!, article, source_url: source_url, digest: digest, revision: "approved")
    state = @publisher.instance_variable_get(:@state)
    state["supervised_publication"] = { "native_revision" => original }
    @publisher.instance_variable_set(:@withdraw_only, true)
    @publisher.instance_variable_set(:@descriptor, { "destination_origin" => "https://ghost.example.test" })

    calls = []
    native = article.merge("updated_at" => "unrelated-native-change")
    ghost = Object.new
    ghost.define_singleton_method(:article) { |_kind, _id| native }
    ghost.define_singleton_method(:withdraw) do |_kind, seen|
      calls << [:withdraw, seen.fetch("id"), seen.fetch("updated_at")]
      uuid = "01234567-1234-1234-1234-0123456789ab"
      native = seen.merge("status" => "draft", "uuid" => uuid, "url" => "https://ghost.example.test/p/#{uuid}/")
    end
    @publisher.instance_variable_set(:@ghost, ghost)
    @publisher.define_singleton_method(:refresh_lease!) { calls << :renew_withdrawal }

    error = assert_raises(Error) { @publisher.send(:prepare_withdrawal, {}) }
    assert_equal "native_ownership_conflict", error.code
    assert_empty calls
    native = article
    @publisher.send(:prepare_withdrawal, {})
    assert_equal [:renew_withdrawal, [:withdraw, article.fetch("id"), original]], calls
    assert_equal "draft", state.fetch("native_baseline").fetch("status")
  end

  def test_failure_code_distinguishes_permanent_public_proof_and_transient_native_errors
    cases = {
      ["public_verification_failed", 200] => "public_verification_failed",
      ["ghost_response_invalid", 200] => "public_verification_failed",
      ["ghost_transport_failed", nil] => "transport_timeout",
      ["ghost_http_error", 429] => "rate_limited",
      ["ghost_http_error", 503] => "native_service_unavailable",
      ["V4-15 work_superseded", 409] => nil,
    }
    cases.each do |(code, status), expected|
      actual = @publisher.send(:failure_code, Error.new(code, status: status))
      expected ? assert_equal(expected, actual) : assert_nil(actual)
    end
  end

  def test_waiting_check_reports_unavailable_evidence_on_the_exact_receiver_context
    connection = Struct.new(:id).new(7)
    row = Struct.new(:cms_mapping, :payload_tree, :context_sha256).new(
      Struct.new(:source_id).new("topic:1"), { "mapping" => {} }, "context",
    )
    @publisher.instance_variable_set(:@source_id, "topic:1")
    @publisher.instance_variable_set(:@connection, connection)
    @publisher.instance_variable_set(:@key, "scope:1")
    @publisher.define_singleton_method(:with_lock) { |&block| block.call }
    @publisher.define_singleton_method(:check_supervised_scope!) {}
    inspections = Object.new
    inspections.define_singleton_method(:find_by) do |inspection_id:, content_connection_id:, status:|
      row if inspection_id == "requested" && content_connection_id == 7 && status == "waiting"
    end
    store = Object.new
    store.define_singleton_method(:get) do |namespace, key|
      raise "wrong publication journal" unless namespace == DiscussionBridgeGhost::Publication::STORE && key == "scope:1"
    end
    reports = []
    receiver = Object.new
    receiver.define_singleton_method(:report) { |*args| reports << args; :reported }
    bridge = Module.new
    cipher = Object.new
    cipher.define_singleton_method(:decrypt) { |tree| tree }
    service = Object.new
    service.define_singleton_method(:new) { |_connection| receiver }
    bridge.const_set(:CmsReceiptCipher, cipher)
    bridge.const_set(:CmsAttentionRecovery, service)

    with_constants(PluginStore: store, DiscussionBridgeCmsAttentionInspection: inspections, DiscussionBridge: bridge) do
      with_publication_validation_stubbed do
        assert_equal :reported, @publisher.inspect_attention("requested")
      end
    end
    assert_equal 1, reports.length
    id, payload = reports.fetch(0)
    assert_equal "requested", id
    assert_equal "context", payload.fetch("context_sha256")
    assert_equal "ghost-dynamic-1", payload.dig("observation", "profile")
    assert_equal "unavailable", payload.dig("observation", "native_state")
  end

  def test_definitive_stale_source_rejection_replaces_only_the_reservation_request
    assert_replaces_stale_reservation("source_revision", "revision_conflict")
  end

  def test_definitive_stale_policy_rejection_replaces_only_the_reservation_request
    assert_replaces_stale_reservation("policy_revision", "policy_changed")
  end

  def test_lost_success_replays_original_reservation_despite_a_newer_intent
    state = reservation_context
    persisted = {}
    @publisher.define_singleton_method(:save!) { persisted.replace(Marshal.load(Marshal.dump(@state))) }
    service = Object.new
    accepted = {}
    inputs = []
    response = Struct.new(:body).new(mapping_result)
    service.define_singleton_method(:prepare) do |input|
      raise "request was not persisted before prepare" unless persisted.fetch("reservation") == input

      inputs << input.dup
      if accepted.empty?
        accepted[input.fetch("mutation_id")] = input.dup
        raise IOError, "response lost after receiver committed"
      end

      raise "a fresh prepare would lose the accepted receipt" unless accepted.fetch(input.fetch("mutation_id")) == input
      response
    end
    @publisher.instance_variable_set(:@mapping_service, service)

    uncertain = nil
    with_receiver_protocol do
      assert_raises(IOError) { @publisher.send(:mapping) }
      state.replace(Marshal.load(Marshal.dump(persisted)))
      uncertain = state.fetch("reservation").dup
      @publisher.instance_variable_set(:@revision, "newer-source")
      @publisher.instance_variable_set(:@descriptor, { "policy" => { "policy_revision" => "newer-policy" } })
      assert_equal mapping_result, @publisher.send(:mapping)
    end
    assert_equal [uncertain, uncertain], inputs
    assert_equal "mapping-1", state.fetch("mapping_id")
    refute state.key?("reservation")
  end

  def test_exact_ordinary_claim_does_not_lease_an_intervening_replacement
    work = Struct.new(:work_id, :retry_of_work_id)
    result = Struct.new(:status)
    selected = work.new("selected-work", nil)
    replacement = work.new("replacement-work", nil)
    @publisher.instance_variable_set(:@current_work, selected)
    @publisher.instance_variable_set(:@mapping, { "mapping_id" => "mapping-1" })
    calls = []
    leased = []
    coordinator = Object.new
    coordinator.define_singleton_method(:claim) do |input, expected_work_id: nil, receipt_path: ""|
      calls << [input, expected_work_id, receipt_path]
      if expected_work_id.nil? || expected_work_id == replacement.work_id
        leased << replacement.work_id
        result.new(200)
      else
        result.new(204)
      end
    end
    @publisher.instance_variable_set(:@work, coordinator)

    assert_equal 204, @publisher.send(:claim_current_work, "old-attempt").status
    assert_empty leased
    assert_equal [
      { "mutation_id" => "old-attempt", "mapping_id" => "mapping-1" }, "selected-work", "selected-work",
    ], calls.fetch(0)

    @publisher.instance_variable_set(:@current_work, replacement)
    assert_equal 200, @publisher.send(:claim_current_work, "new-attempt").status
    assert_equal ["replacement-work"], leased
  end

  private

  def assert_replaces_stale_reservation(field, code)
    state = reservation_context
    old = {
      "mutation_id" => "prior-attempt", "source_id" => "topic:1",
      "source_revision" => "source-now", "policy_revision" => "policy-now",
      "external_id" => "ghost-post:stable-owner", "canonical_url" => URL,
    }
    old[field] = "superseded"
    state["reservation"] = old
    inputs = []
    service = Object.new
    response = Struct.new(:body).new(mapping_result)
    service.define_singleton_method(:prepare) do |input|
      raise "request was not persisted before prepare" unless state.fetch("reservation") == input

      inputs << input.dup
      raise ::DiscussionBridge::CmsProtocol::Error.new(code) if inputs.size == 1

      response
    end
    @publisher.instance_variable_set(:@mapping_service, service)

    with_receiver_protocol { assert_equal mapping_result, @publisher.send(:mapping) }
    assert_equal old, inputs.fetch(0)
    fresh = inputs.fetch(1)
    refute_equal old.fetch("mutation_id"), fresh.fetch("mutation_id")
    assert_equal "source-now", fresh.fetch("source_revision")
    assert_equal "policy-now", fresh.fetch("policy_revision")
    assert_equal old.slice("source_id", "external_id", "canonical_url"), fresh.slice("source_id", "external_id", "canonical_url")
    assert_equal "stable-owner", state.fetch("owner")
    assert_equal "article", state.fetch("slug")
    assert_equal "mapping-1", state.fetch("mapping_id")
    refute state.key?("reservation")
  end

  def with_receiver_protocol(&block)
    protocol = Module.new
    protocol.const_set(:ERRORS, {
      "revision_conflict" => { "http" => 409 }, "policy_changed" => { "http" => 409 },
    })
    error_type = Class.new(StandardError) do
      attr_reader :code

      def initialize(code)
        @code = code
        super
      end
    end
    protocol.const_set(:Error, error_type)
    bridge = Module.new
    bridge.const_set(:CmsProtocol, protocol)
    with_constants(DiscussionBridge: bridge, &block)
  end

  def reservation_context
    @publisher.instance_variable_set(:@source_id, "topic:1")
    @publisher.instance_variable_set(:@action, "publish_revision")
    @publisher.instance_variable_set(:@revision, "source-now")
    @publisher.instance_variable_set(:@descriptor, { "policy" => { "policy_revision" => "policy-now" } })
    state = { "owner" => "stable-owner", "slug" => "article", "external_id" => "ghost-post:stable-owner", "url" => URL }
    @publisher.instance_variable_set(:@state, state)
    state
  end

  def mapping_result
    {
      "mapping_id" => "mapping-1", "source_id" => "topic:1", "canonical_url" => URL,
      "external_id" => "ghost-post:stable-owner", "presentation_mode" => "simple", "destination_native_id" => nil,
    }
  end

  def stub_article(article)
    test = self
    ghost = Object.new
    ghost.define_singleton_method(:article) do |kind, native_id|
      test.assert_equal ["post", "native-1"], [kind, native_id]
      article
    end
    @publisher.instance_variable_set(:@ghost, ghost)
  end

  def with_publication_validation_stubbed
    klass = DiscussionBridgeGhost::Publication
    methods = %i[validate_policy! validate_destination!].to_h { |name| [name, klass.method(name)] }
    methods.each_key { |name| klass.define_singleton_method(name) { |*| } }
    yield
  ensure
    methods.each { |name, implementation| klass.define_singleton_method(name, implementation) }
  end

  def with_constants(**values)
    previous = values.to_h do |name, value|
      old = Object.const_defined?(name, false) ? Object.send(:remove_const, name) : nil
      Object.const_set(name, value)
      [name, old]
    end
    yield
  ensure
    previous&.each do |name, value|
      Object.send(:remove_const, name)
      Object.const_set(name, value) if value
    end
  end

  def owned_article
    {
      "id" => "native-1", "title" => "Owned publication", "status" => "published", "url" => URL,
      "updated_at" => "2026-11-08T22:30:00.000Z", "html" => "<section>owned</section>",
    }
  end
end
