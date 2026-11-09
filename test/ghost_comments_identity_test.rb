# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/discussion_bridge_ghost/inbound_publishing"

module DiscussionBridge
  module CmsReceiptCipher
    def self.decrypt(encrypted)
      if encrypted == "outbound-encrypted"
        return { "admin_url" => "https://admin.ghost.example", "admin_key" => "synthetic-admin-key" }
      end

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
      attr_accessor :entry, :last_query, :published_url, :reads

      def public_article(url)
        reads << [:public_page, url]
        [200, "matching owner fragment, which can also be copied"]
      end
    end

    def initialize(url, admin_key = nil, content_key: nil)
      if admin_key
        raise "unexpected credential scope" unless url == "https://admin.ghost.example" && admin_key == "synthetic-admin-key"
      end
    end

    def public_entry(kind, id:, tag:)
      self.class.last_query = [kind, id, tag]
      self.class.entry
    end

    def published_article_url(kind, id)
      self.class.reads << [:native_identity, kind, id]
      self.class.published_url
    end
  end

  module AutomaticPublishing
    SETTINGS = "outbound"
  end

  module PostPresentation
    def self.current_page?(html, owner:, resource:, native_id:, revision:)
      html == "matching owner fragment, which can also be copied"
    end
  end
end

module PluginStore
  class << self
    attr_accessor :outbound

    def get(store, _connection_id)
      store == "outbound" ? outbound : "encrypted"
    end
  end
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
  OUTBOUND = Data.define(:role, :content_connection).new("presentation", CONNECTION)
  OWNED = { owner: "owner", resource: "resource", native_id: ORIGINAL_ID, revision: "revision", kind: "post" }.freeze

  def setup
    PluginStore.outbound = "outbound-encrypted"
    DiscussionBridgeGhost::GhostSite.reads = []
    DiscussionBridgeGhost::GhostSite.published_url = nil
  end

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

  def test_copied_outbound_fragment_requires_the_original_current_public_native_article
    controller = DiscussionBridgeGhost::PublicCommentsController.new
    link = DiscussionBridgeGhost::PublicCommentsController::PublicLink.new(OUTBOUND, Object.new, OWNED)
    refute controller.send(:current_native_page?, link, URL), "old exact URL displays a copied fragment after the original disappeared"
    assert_equal [[:public_page, URL], [:native_identity, "post", ORIGINAL_ID]], DiscussionBridgeGhost::GhostSite.reads

    DiscussionBridgeGhost::GhostSite.published_url = "https://ghost.example/moved/"
    refute controller.send(:current_native_page?, link, URL), "original exists at a different URL"

    DiscussionBridgeGhost::GhostSite.published_url = URL
    assert controller.send(:current_native_page?, link, URL), "original is verified independently of the matching HTML"
  end

  def test_manual_publication_without_a_saved_outbound_credential_refuses_live_replies
    PluginStore.outbound = nil
    controller = DiscussionBridgeGhost::PublicCommentsController.new
    link = DiscussionBridgeGhost::PublicCommentsController::PublicLink.new(OUTBOUND, Object.new, OWNED)
    refute controller.send(:current_native_page?, link, URL)
    assert_empty DiscussionBridgeGhost::GhostSite.reads
  end
end
