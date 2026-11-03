# frozen_string_literal: true

require "rails_helper"
require_relative "../../lib/discussion_bridge_ghost/ownership_receipt"

RSpec.describe DiscussionBridgeGhost::OwnershipReceipt do
  let(:protocol) { DiscussionBridgeGhost::WireProtocol.new }
  let(:value) do
    {
      "schema_version" => "db-native-ownership-1",
      "forum_origin" => "https://forum.example",
      "connection_id" => "dbc_#{"a" * 24}",
      "mapping_id" => "76f0e743-1549-4f35-969b-47e94440ccba",
      "resource_id" => "7de62217-cdd1-477f-ab79-8ba2af9cbe79",
      "source_id" => "topic:雪",
      "external_id" => "ghost-post:α",
      "native_id" => "0123456789abcdef01234567",
      "canonical_url" => "https://ghost.example/article/%E9%9B%AA/",
      "source_revision" => "revision:é",
      "last_lease_generation" => 23,
      "move_id" => nil,
      "proof_nonce" => nil
    }
  end

  it "validates actual V4 types then snapshots the exact immutable ownership value" do
    input = JSON.parse(JSON.generate(value))
    receipt = described_class.new(input, protocol: protocol)
    expect(receipt.sha256).to eq(
      "663af58005b59f0190e420406ec6fe8fc3a3c4c0d138396422de8e1e2eba35c2"
    )
    input.fetch("source_revision").replace("changed")
    expect(receipt.value.fetch("source_revision")).to eq("revision:é")
    expect {
      receipt.value.fetch("native_id").replace("changed")
    }.to raise_error(FrozenError)
    expect { receipt.value["mapping_id"] = nil }.to raise_error(FrozenError)
    expect(receipt.inspect).not_to include("ghost.example", "topic:雪")
  end

  it "preserves valid To-direction null mapping/revision and zero generation without inventing a From lease" do
    receipt =
      described_class.new(
        value.merge(
          "mapping_id" => nil,
          "source_revision" => nil,
          "last_lease_generation" => 0
        ),
        protocol: protocol
      )
    expect(receipt.sha256).to eq(
      "47b4528f3f79f2ae9d59c9f428fda2cff483583b71a1f4a339546df701f65c8c"
    )
  end

  it "rejects extra/missing fields, invalid typed values and duplicate JSON aliases" do
    [
      value.merge("lease_token" => "SYNTHETIC-not-allowed"),
      value.except("resource_id"),
      value.merge("last_lease_generation" => "23"),
      value.merge("source_revision" => false),
      value.merge("mapping_id" => "not-a-uuid"),
      value.merge("schema_version" => "unknown"),
      value.merge(native_id: "conflicting-json-name")
    ].each do |invalid|
      expect {
        described_class.new(invalid, protocol: protocol)
      }.to raise_error(DiscussionBridgeGhost::Error)
    end
  end
end
