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

  private

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
