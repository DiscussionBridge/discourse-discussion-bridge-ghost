# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/discussion_bridge_ghost/inbound_publishing"

module DiscussionBridge
  module CmsReceiptCipher
    def self.decrypt(_encrypted)
      { "admin_url" => "https://ghost.example", "content_key" => "a" * 26, "tag" => "discussion" }
    end
  end

  module CanonicalSource
    def self.call(connection_id:, source_url:)
      Struct.new(:source_url).new(source_url)
    end
  end

  module CmsConfiguration
    class << self
      attr_reader :checked

      def eligible?(topic, policy)
        @checked = [topic, policy]
        false
      end
    end
  end
end

module DiscussionBridgeGhost
  class GhostSite
    class << self
      attr_accessor :entry, :last_query
    end

    def initialize(_url, content_key:); end

    def public_entry(kind, id:, tag:)
      self.class.last_query = [kind, id, tag]
      self.class.entry
    end
  end
end

module PluginStore
  def self.get(*) = "encrypted"
end

class ApplicationController
  def self.requires_plugin(*) = nil
  def self.skip_before_action(*, **) = nil
end

require_relative "../app/controllers/discussion_bridge_ghost/public_comments_controller"

class GhostCommentsIdentityTest < Minitest::Test
  ORIGINAL_ID = "0123456789abcdef01234567"
  REPLACEMENT_ID = "abcdef0123456789abcdef01"
  URL = "https://ghost.example/roundup/"
  CONNECTION = Data.define(:public_id).new("ghost")
  BINDING = Data.define(:external_id, :canonical_url, :content_connection)
    .new("ghost-post:#{ORIGINAL_ID}", URL, CONNECTION)

  def entry(id: ORIGINAL_ID, url: URL, visibility: "public", tag: "discussion")
    { "id" => id, "url" => url, "visibility" => visibility, "access" => true, "tags" => [{ "slug" => tag }] }
  end

  def proof_for(content)
    DiscussionBridgeGhost::GhostSite.entry = content
    result = DiscussionBridgeGhost::InboundPublishing.current_source?(BINDING)
    assert_equal ["post", ORIGINAL_ID, "discussion"], DiscussionBridgeGhost::GhostSite.last_query
    result
  end

  def test_ghost_must_still_attest_the_original_public_tagged_article_at_the_bound_url
    assert proof_for(entry)
    refute proof_for(nil), "removed native article"
    refute proof_for(entry(id: REPLACEMENT_ID)), "URL reused by another native article"
    refute proof_for(entry(url: "https://ghost.example/new-roundup/")), "original moved away"
    refute proof_for(entry(visibility: "members")), "article no longer public"
    refute proof_for(entry(tag: "other")), "article no longer selected"
  end

  def test_outbound_policy_is_checked_before_using_a_previously_verified_mapping
    binding = Data.define(:role, :presentation_mode).new("presentation", "simple")
    controller = DiscussionBridgeGhost::PublicCommentsController.new
    policy = { "presentation_mode" => "simple", "author_ids" => [], "taxonomy_ids" => [] }
    topic = Object.new
    assert_nil controller.send(:outbound_identity, binding, nil, topic, policy)
    assert_equal [topic, policy], DiscussionBridge::CmsConfiguration.checked
  end
end
