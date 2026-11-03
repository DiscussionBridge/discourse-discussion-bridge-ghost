# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/discussion_bridge_ghost/protected_diagnostics"
require_relative "../lib/discussion_bridge_ghost/ownership_receipt"

# Private framing algorithm only. Public shape/type validation uses the actual
# pinned wire codec in native RSpec; this standalone harness does not fake one.
class GhostOwnershipReceiptFramingTest < Minitest::Test
  def receipt
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

  def fingerprint(value)
    DiscussionBridgeGhost::OwnershipReceipt.send(:canonical_fingerprint, value)
  end

  def test_unicode_byte_lengths_and_exact_field_order_match_independent_node_vector
    expected =
      "663af58005b59f0190e420406ec6fe8fc3a3c4c0d138396422de8e1e2eba35c2"
    assert_equal expected, fingerprint(receipt)
    assert_equal expected, fingerprint(receipt.to_a.reverse.to_h)
  end

  def test_null_and_zero_use_the_normative_frames_not_empty_strings
    nullable =
      receipt.merge(
        "mapping_id" => nil,
        "source_revision" => nil,
        "last_lease_generation" => 0
      )
    assert_equal "47b4528f3f79f2ae9d59c9f428fda2cff483583b71a1f4a339546df701f65c8c",
                 fingerprint(nullable)
    # Empty revision is an ALGORITHM control, not a valid public receipt.
    refute_equal fingerprint(receipt.merge("source_revision" => nil)),
                 fingerprint(receipt.merge("source_revision" => ""))
  end

  def test_framing_does_not_normalize_unicode_or_url_octets
    refute_equal fingerprint(receipt),
                 fingerprint(
                   receipt.merge("source_revision" => "revision:e\u0301")
                 )
    refute_equal fingerprint(receipt),
                 fingerprint(
                   receipt.merge(
                     "canonical_url" =>
                       "https://ghost.example/article/%e9%9b%aa/"
                   )
                 )
  end
end
