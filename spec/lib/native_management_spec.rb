# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/discussion_bridge_ghost/native_management"

RSpec.describe DiscussionBridgeGhost::NativeManagement do
  let(:protocol) { DiscussionBridgeGhost::WireProtocol.new }
  let(:resource) { SecureRandom.uuid }
  let(:author_a) { "a" * 24 }
  let(:author_b) { "b" * 24 }
  let(:tag_x) { "c" * 24 }
  let(:tag_y) { "d" * 24 }
  let(:policy) do
    {
      "policy_revision" => SecureRandom.uuid,
      "enabled" => true,
      "selection" => "all_public",
      "category_ids" => [],
      "include_topic_ids" => [],
      "exclude_topic_ids" => [],
      "include_unlisted" => false,
      "publication_kind" => "dynamic",
      "presentation_mode" => "simple",
      "author_ids" => [],
      "taxonomy_ids" => []
    }
  end

  def intent(stage = "publish", selected = policy)
    described_class.for_policy(
      protocol: protocol,
      policy: selected,
      stage: stage
    )
  end

  def command(management)
    stage = management.value.fetch("stage")
    baseline_tags = [
      { "id" => "e" * 24, "name" => "#discussionbridge-resource-#{resource}" }
    ]
    fields = {
      "status" => stage == "publish" ? "published" : "draft",
      "lexical" => '{"root":{"children":[]}}'
    }
    fields.delete("lexical") if stage == "withdraw"
    unless stage == "withdraw"
      fields.merge!(
        "title" => "Publication",
        "slug" => "article",
        "visibility" => "public",
        "tags" => baseline_tags
      )
    end
    fields["published_at"] = "2026-11-03T12:00:00.000Z" if stage == "publish"
    if management.value.fetch("author_ids")
      fields["authors"] = management
        .value
        .fetch("author_ids")
        .map { |id| { "id" => id } }
    end
    if management.value.fetch("taxonomy_ids")
      fields["tags"] = management
        .value
        .fetch("taxonomy_ids")
        .map { |id| { "id" => id } } + baseline_tags
    end
    {
      "identity" => {
        "resource_id" => resource,
        "kind" => "post",
        "native_id" => stage == "create_draft" ? nil : "f" * 24
      },
      "owner" => {
        "direction" => "from_discourse",
        "action" => stage,
        "move_id" => nil,
        "proof_nonce" => nil
      },
      "baseline" => stage == "create_draft" ? nil : { "tags" => baseline_tags },
      "candidate" => fields.merge("management" => management.value),
      "request" => {
        "body_bytes" => JSON.generate("posts" => [fields]),
        "maximum_bytes" => 262_144
      }
    }
  end

  def change_fields(value)
    fields = JSON.parse(value.dig("request", "body_bytes")).fetch("posts").first
    yield fields
    value["candidate"] = fields.merge(
      "management" => value.dig("candidate", "management")
    )
    value["request"]["body_bytes"] = JSON.generate("posts" => [fields])
  end

  it "retains detached original intent without adding it to Ghost native payloads" do
    policy["author_ids"] = [author_a, author_b]
    policy["taxonomy_ids"] = [tag_x, tag_y]
    management = intent
    value = command(management)
    expect(management.validate_command!(value)).to eq(true)
    expect(
      JSON.parse(value.dig("request", "body_bytes")).fetch("posts").first
    ).not_to have_key("management")
    expect(
      DiscussionBridgeGhost::NativeDocument.new(value).fields
    ).not_to have_key("management")
    expect(management.value).to be_frozen
    expect(management.value.fetch("author_ids")).to be_frozen
    policy["author_ids"].reverse!
    expect(management.value.fetch("author_ids")).to eq([author_a, author_b])
    expect(management.inspect).not_to include(author_a, tag_x)
    value["request"]["body_bytes"] = JSON.generate(
      "posts" => [value.fetch("candidate")]
    )
    expect { management.validate_command!(value) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
  end

  it "distinguishes policy intent from metadata not yet applied by draft creation or withdrawal" do
    policy["author_ids"] = [author_a]
    policy["taxonomy_ids"] = [tag_x]
    %w[create_draft withdraw].each do |stage|
      management = intent(stage)
      expect(management.value.fetch("author_ids")).to eq(nil)
      expect(management.value.fetch("taxonomy_ids")).to eq(nil)
      expect(management.validate_command!(command(management))).to eq(true)
      expect(management.assert_policy!(policy)).to eq(true)
      invalid = command(management)
      change_fields(invalid) do |fields|
        fields["authors"] = [{ "id" => author_a }]
      end
      expect { management.validate_command!(invalid) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    expect(intent("create_draft").value.fetch("scalar_fields")).not_to include(
      "published_at"
    )
    expect(intent("withdraw").value.fetch("scalar_fields")).to eq(["status"])
  end

  it "checks the new descriptor against current policy without rewriting an earlier one" do
    policy["author_ids"] = [author_a]
    old = intent
    old_bytes = JSON.generate(old.value)
    updated =
      policy.merge(
        "policy_revision" => SecureRandom.uuid,
        "author_ids" => [author_b]
      )
    current = intent("publish", updated)
    expect(current.assert_policy!(updated)).to eq(true)
    expect { old.assert_policy!(updated) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    expect(JSON.generate(old.value)).to eq(old_bytes)
    expect(old.assert_policy!(policy)).to eq(true)
  end

  it "preserves multiple author order and refuses missing, swapped or substituted native selections" do
    policy["author_ids"] = [author_a, author_b]
    policy["taxonomy_ids"] = [tag_x, tag_y]
    management = intent
    expect(management.validate_command!(command(management))).to eq(true)
    %w[authors tags].each do |name|
      value = command(management)
      change_fields(value) { |fields| fields[name].reverse! }
      expect { management.validate_command!(value) }.to raise_error(
        DiscussionBridgeGhost::Error
      )
    end
    value = command(management)
    change_fields(value) { |fields| fields.delete("authors") }
    expect { management.validate_command!(value) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
  end

  it "preserves native authors and non-automation tags when selections are empty" do
    management = intent
    value = command(management)
    extra = { "id" => tag_x, "name" => "Operator tag" }
    value["baseline"]["tags"] << extra
    change_fields(value) { |fields| fields["tags"] << extra }
    expect(management.validate_command!(value)).to eq(true)
    change_fields(value) do |fields|
      fields["tags"].reject! { |tag| tag["id"] == tag_x }
    end
    expect { management.validate_command!(value) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    value = command(management)
    change_fields(value) { |fields| fields["authors"] = [{ "id" => author_a }] }
    expect { management.validate_command!(value) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
  end

  it "retains explicit whole taxonomy selection semantics rather than inventing membership-only ownership" do
    policy["taxonomy_ids"] = [tag_y]
    management = intent
    value = command(management)
    value["baseline"]["tags"] << {
      "id" => tag_x,
      "name" => "Earlier selection"
    }
    expect(management.validate_command!(value)).to eq(true)
    change_fields(value) do |fields|
      fields["tags"] << { "id" => "9" * 24, "name" => "Unexpected relation" }
    end
    expect { management.validate_command!(value) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    # This checks declared request intent ONLY. Prior proven managed-baseline
    # and current authority checks are still required before any actual write.
  end

  it "refuses a copied unrelated native setting, mismatched stage, foreign resource marker or missing managed scalar" do
    management = intent
    value = command(management)
    change_fields(value) do |fields|
      fields["custom_excerpt"] = "Copied native setting is not managed intent"
    end
    expect { management.validate_command!(value) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    value = command(management)
    value["owner"]["action"] = "withdraw"
    expect { management.validate_command!(value) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    value = command(management)
    change_fields(value) do |fields|
      fields["tags"] << {
        "name" => "#discussionbridge-resource-#{SecureRandom.uuid}"
      }
    end
    expect { management.validate_command!(value) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
    value = command(management)
    change_fields(value) { |fields| fields.delete("title") }
    expect { management.validate_command!(value) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
  end

  it "rejects unknown or altered descriptor shapes and does not manufacture one for older physical history" do
    original = intent.value
    changes = [
      { "format" => "unknown" },
      { "stage" => "source_move" },
      { "extra" => true },
      { "scalar_fields" => ["status"] },
      { "author_ids" => [] },
      { "author_ids" => [author_a, author_a] },
      { "taxonomy_ids" => [] },
      { "taxonomy_ids" => ["not-native"] }
    ]
    changes.each do |change|
      expect {
        described_class.new(protocol: protocol, value: original.merge(change))
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
    expect {
      described_class.new(protocol: protocol, value: nil)
    }.to raise_error(DiscussionBridgeGhost::Error)
    value = command(intent)
    value["candidate"].delete("management")
    expect { intent.validate_command!(value) }.to raise_error(
      DiscussionBridgeGhost::Error
    )
  end
end
