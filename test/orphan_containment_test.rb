# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/discussion_bridge_ghost/ghost_site"
require_relative "../lib/discussion_bridge_ghost/publication"
require_relative "../lib/discussion_bridge_ghost/orphan_containment"

class OrphanContainmentTest < Minitest::Test
  Error = DiscussionBridgeGhost::Error
  URL = "https://ghost.example.test/article/"
  UUID = "67b3b9a7-75db-49bb-9c48-2a417e904ea2"
  NATIVE_ID = "0123456789abcdef01234567"
  SOURCE_URL = "https://discourse.example.test/t/1"
  REVISION = "source-revision"
  TIME = "2026-11-09T01:00:00Z"
  NEXT_TIME = "2026-11-09T01:00:01Z"
  WORK_ID = "retained-work"
  CONFIRM = "revert-to-draft:#{NATIVE_ID}"

  class GhostFixture
    attr_reader :writes
    attr_accessor :public_override, :after_withdraw

    def initialize(article)
      @article = article
      @writes = []
    end

    def article(kind, id)
      raise "wrong native identity" unless kind == "post" && id == NATIVE_ID
      @article.dup
    end

    def public_article(url)
      raise "wrong public URL" unless url == URL
      @public_override || (@article["status"] == "published" ? [200, @article["html"]] : [404, nil])
    end

    def withdraw(kind, article)
      raise "wrong native identity" unless kind == "post" && article["id"] == NATIVE_ID
      raise "unsafe conditional write" unless article["updated_at"] == @article["updated_at"]
      @writes << article["updated_at"]
      @article = @article.merge("status" => "draft", "url" => "https://ghost.example.test/p/#{UUID}/", "updated_at" => NEXT_TIME)
      @after_withdraw&.call(self)
    end
  end

  Work = Struct.new(:state, :action, :source_revision, :source_snapshot)
  WorkItems = Struct.new(:item) do
    def find_by(work_id:)
      item if work_id == WORK_ID
    end
  end
  Mapping = Struct.new(:work_items)

  def setup
    @ghost = GhostFixture.new("id" => NATIVE_ID, "uuid" => UUID, "title" => "Article", "status" => "published",
                             "url" => URL, "updated_at" => TIME, "html" => "managed content")
    @work = Work.new("cancelled", "publish_revision", REVISION, { "title" => "Article", "topic_url" => SOURCE_URL })
    mapping = Mapping.new(WorkItems.new(@work))
    @worker = DiscussionBridgeGhost::OrphanContainment.allocate
    @worker.instance_variable_set(:@ghost, @ghost)
    @worker.instance_variable_set(:@connection, Struct.new(:public_id).new("connection"))
    @worker.instance_variable_set(:@mapping, { "mapping_id" => "mapping", "mapping_state" => "attention" })
    @worker.instance_variable_set(:@descriptor, { "destination_origin" => "https://ghost.example.test" })
    @worker.instance_variable_set(:@state, {
      "url" => URL, "operation" => { "publish_started" => true, "work_id" => WORK_ID, "html" => "managed content",
                                    "revision" => REVISION, "title" => "Article", "source_url" => SOURCE_URL },
    })
    @worker.instance_variable_set(:@topic_id, 1)
    @worker.instance_variable_set(:@kind, "post")
    @worker.instance_variable_set(:@native_id, NATIVE_ID)
    @worker.instance_variable_set(:@canonical_url, URL)
    @worker.define_singleton_method(:assert_owned!) do |article|
      raise Error.new("native_ownership_conflict") unless article["id"] == NATIVE_ID
    end
    @worker.define_singleton_method(:managed_article?) { |html, revision| html == "managed content" && revision == REVISION }
    @worker.define_singleton_method(:fragment_digest) { |html, source_url:| Digest::SHA256.hexdigest("#{source_url}:#{html}") }
    # Only the database and HTML parser are substituted. Dispatch, public proof,
    # exact revision checks, conditional Ghost writes and final proof run below.
    @worker.define_singleton_method(:with_target) do |&block|
      article = @ghost.article(@kind, @native_id)
      proof = retained_dispatch!(mapping, article)
      status = article["status"] == "published" ? prove_public_target!(proof) : public_absence!
      block.call(article, proof, status)
    end
  end

  def test_plan_is_read_only_and_exposes_exact_revision
    plan = @worker.plan
    assert_empty @ghost.writes
    assert_equal TIME, plan.fetch(:native_revision)
    assert_equal "published", plan.fetch(:native_status)
    assert_equal "attention", plan.fetch(:receiver_mapping_state)
    assert_equal WORK_ID, plan.fetch(:receiver_work_id)
  end

  def test_only_an_exactly_confirmed_revision_is_conditionally_drafted
    result = @worker.call(native_revision: TIME, confirm: CONFIRM)
    assert_equal [TIME], @ghost.writes
    assert_equal "contained", result.fetch(:outcome)
    assert_equal "draft", result.fetch(:native_status)
    assert_equal 404, result.fetch(:public_status)
    assert_equal NEXT_TIME, result.fetch(:native_revision)
    assert_equal "attention", result.fetch(:receiver_mapping_state)
    assert_equal "already_draft", @worker.call(native_revision: NEXT_TIME, confirm: CONFIRM).fetch(:outcome)
    assert_equal [TIME], @ghost.writes
  end

  def test_rejects_wrong_confirmation_and_stale_revision_without_a_write
    assert_equal "ghost_containment_confirmation_required",
                 assert_raises(Error) { @worker.call(native_revision: TIME, confirm: "yes") }.code
    assert_equal "ghost_containment_revision_changed",
                 assert_raises(Error) { @worker.call(native_revision: NEXT_TIME, confirm: CONFIRM) }.code
    assert_empty @ghost.writes
  end

  def test_rejects_unrelated_public_response_and_nonterminal_dispatch
    @ghost.public_override = [200, "foreign"]
    assert_equal "ghost_containment_native_proof_missing",
                 assert_raises(Error) { @worker.call(native_revision: TIME, confirm: CONFIRM) }.code
    @ghost.public_override = nil
    @work.state = "leased"
    assert_equal "ghost_containment_native_proof_missing",
                 assert_raises(Error) { @worker.call(native_revision: TIME, confirm: CONFIRM) }.code
    assert_empty @ghost.writes
  end

  def test_draft_write_without_verified_public_absence_is_not_success
    @ghost.after_withdraw = ->(ghost) { ghost.public_override = [200, "managed content"] }
    assert_equal "public_verification_failed",
                 assert_raises(Error) { @worker.call(native_revision: TIME, confirm: CONFIRM) }.code
    assert_equal [TIME], @ghost.writes
  end
end
