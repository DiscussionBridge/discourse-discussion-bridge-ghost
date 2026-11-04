# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/discussion_bridge_ghost/error"
require_relative "../lib/discussion_bridge_ghost/protected_diagnostics"
require_relative "../lib/discussion_bridge_ghost/wire_json"
require_relative "../lib/discussion_bridge_ghost/native_document"
require_relative "../lib/discussion_bridge_ghost/native_metadata_selection"

class GhostNativeDocumentTest < Minitest::Test
  ID = "a" * 24
  AUTHOR = "b" * 24
  TAG = "c" * 24

  def test_metadata_checkpoint_copy_is_mutable_without_weakening_strict_decoding
    parsed =
      DiscussionBridgeGhost::NativeDocument.parse(
        '{"offsets":{"authors":0},"items":{"authors":[{"id":"original"}]}}',
        maximum_bytes: 1024
      )
    assert_raises(DiscussionBridgeGhost::Error) do
      parsed.fetch("offsets")["authors"] = 1
    end
    # Isolated actual copy/snapshot methods only: no context, authority, DB or
    # native HTTP construction/execution is implied by this portable regression.
    helper = DiscussionBridgeGhost::NativeMetadataSelection.allocate
    copy = helper.send(:mutable, parsed)
    assert_instance_of Hash, copy
    assert_instance_of Hash, copy.fetch("offsets")
    copy.fetch("offsets")["authors"] = 1
    copy.fetch("items").fetch("authors").first["id"] = "changed"
    assert_equal 0, parsed.dig("offsets", "authors")
    assert_equal "original", parsed.dig("items", "authors", 0, "id")
    sealed = helper.send(:snapshot, copy)
    assert sealed.frozen?
    assert sealed.fetch("offsets").frozen?
    assert sealed.dig("items", "authors", 0, "id").frozen?
    assert_raises(FrozenError) { sealed.fetch("offsets")["authors"] = 2 }
    assert_raises(DiscussionBridgeGhost::Error) do
      DiscussionBridgeGhost::NativeDocument.parse(
        '{"x":1,"x":2}',
        maximum_bytes: 1024
      )
    end
  end

  def setup
    @baseline = {
      "id" => ID,
      "type" => "post",
      "title" => "Old title",
      "slug" => "article",
      "updated_at" => "2026-11-03T10:00:00.000Z",
      "status" => "published",
      "visibility" => "public",
      "lexical" => '{"root":{"children":[{"type":"paragraph","width":1.5}]}}',
      "authors" => [{ "id" => AUTHOR, "name" => "Original author" }],
      "tags" => [{ "id" => TAG, "name" => "Original tag" }],
      "codeinjection_head" => "Unrelated head content",
      "custom_template" => "special"
    }
    @fields = {
      "id" => ID,
      "updated_at" => @baseline["updated_at"],
      "title" => "New title",
      "status" => "published"
    }
    @current =
      @baseline.merge(@fields).merge(
        "updated_at" => "2026-11-03T10:01:00.000Z",
        "html" => "<p>Native rendering</p>"
      )
    @command = {
      "identity" => {
        "kind" => "post",
        "native_id" => ID
      },
      "request" => {
        "maximum_bytes" => 262_144,
        "body_bytes" => JSON.generate("posts" => [@fields])
      },
      "baseline" => @baseline,
      "candidate" => @fields
    }
  end

  def document
    DiscussionBridgeGhost::NativeDocument.new(@command)
  end

  def test_verifies_complete_native_readback_and_unrelated_metadata
    assert document.verify!(response: @current, current: @current)
    %w[
      codeinjection_head
      custom_template
      visibility
      lexical
      authors
      tags
    ].each do |key|
      bad = @current.merge(key => nil)
      assert_raises(DiscussionBridgeGhost::Error, key) do
        document.verify!(response: @current, current: bad)
      end
    end
  end

  def test_rejects_wrong_kind_identity_and_changed_native_edition
    [
      { "id" => "d" * 24 },
      { "type" => "page" },
      { "updated_at" => "2026-11-03T10:02:00.000Z" },
      { "title" => "Wrong title" }
    ].each do |delta|
      assert_raises(DiscussionBridgeGhost::Error) do
        document.verify!(response: @current, current: @current.merge(delta))
      end
    end
  end

  def test_semantic_lexical_comparison_retains_fractional_editor_metadata
    current =
      @current.merge(
        "lexical" =>
          ' { "root": { "children": [{"width":1.5,"type":"paragraph"}] } } '
      )
    assert document.verify!(response: @current, current: current)
    assert_raises(DiscussionBridgeGhost::Error) do
      document.verify!(
        response: @current,
        current: current.merge("lexical" => '{"root":{"children":[]}}')
      )
    end
  end

  def test_relations_are_ordered_and_identified_not_merged_or_matched_by_display_name
    @fields["authors"] = [{ "id" => AUTHOR }]
    @fields["tags"] = [{ "name" => "#discussionbridge-resource-example" }]
    @command["request"]["body_bytes"] = JSON.generate("posts" => [@fields])
    current =
      @current.merge(
        "tags" => [
          { "id" => TAG, "name" => "#discussionbridge-resource-example" }
        ]
      )
    assert document.verify!(response: current, current: current)
    assert_raises(DiscussionBridgeGhost::Error) do
      document.verify!(
        response: current,
        current:
          current.merge(
            "authors" => [{ "id" => "e" * 24, "name" => "Original author" }]
          )
      )
    end
    assert_raises(DiscussionBridgeGhost::Error) do
      document.verify!(
        response: current,
        current: current.merge("tags" => current["tags"] * 2)
      )
    end
  end

  def test_rejects_duplicate_json_wrong_native_container_and_nonfinite_values
    [
      '{"posts":[],"posts":[]}',
      '{"posts":[{}],"pages":[]}',
      '{"posts":[]}',
      '{"posts":[{"id":"bad"}]}',
      '{"posts":[NaN]}'
    ].each do |bytes|
      assert_raises(DiscussionBridgeGhost::Error) do
        document.response_object(bytes)
      end
    end
  end

  def test_request_and_candidate_must_agree_and_only_known_writable_fields_are_accepted
    @command["candidate"] = @fields.merge("title" => "Different")
    assert_raises(DiscussionBridgeGhost::Error) { document }
    @command["candidate"] = @fields
    @fields["newsletter"] = "not-authorized-by-this-operation"
    @command["request"]["body_bytes"] = JSON.generate("posts" => [@fields])
    assert_raises(DiscussionBridgeGhost::Error) { document }
  end

  def test_native_date_format_may_differ_but_precision_and_unrelated_identity_cannot
    @fields["published_at"] = "2026-11-03T10:00:00Z"
    @command["request"]["body_bytes"] = JSON.generate("posts" => [@fields])
    current =
      @current.merge(
        "published_at" => "2026-11-03T10:00:00.000Z",
        "comment_id" => ID,
        "email" => nil
      )
    assert document.verify!(response: current, current: current)
    assert_raises(DiscussionBridgeGhost::Error) do
      document.verify!(
        response: current,
        current: current.merge("published_at" => "2026-11-03T10:00:00.001Z")
      )
    end
    assert_raises(DiscussionBridgeGhost::Error) do
      document.verify!(
        response: current,
        current: current.merge("comment_id" => "d" * 24)
      )
    end
    assert_raises(DiscussionBridgeGhost::Error) do
      document.verify!(
        response: current,
        current: current.merge("email" => { "id" => "d" * 24 })
      )
    end
  end
end
