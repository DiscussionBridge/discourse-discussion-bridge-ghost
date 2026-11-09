# frozen_string_literal: true

module DiscussionBridgeGhost
  class PublicCommentsController < ::ApplicationController
    requires_plugin "discourse-discussion-bridge-ghost"
    skip_before_action :check_xhr, only: :loader
    # The static script is intentionally embedded by Ghost on another origin.
    skip_before_action :verify_authenticity_token, only: :loader

    LOADER = File.binread(File.expand_path("../../../public/comments.js", __dir__)).freeze

    def loader
      render plain: LOADER, content_type: "application/javascript"
    end

    def show
      response.headers["Cache-Control"] = "no-store"
      origin = request.headers["Origin"]
      topic = public_topic(params[:url], origin)
      raise Discourse::NotFound unless topic

      response.headers["Access-Control-Allow-Origin"] = origin
      response.headers["Vary"] = [response.headers["Vary"], "Origin"].compact.join(", ")
      render json: {
        topic_path: topic.relative_url,
        replies: PostPresentation.public_replies(topic, Guardian.new),
        title: I18n.t("discussion_bridge_ghost.comments.title"),
        empty: I18n.t("discussion_bridge_ghost.comments.empty"),
        discussion: I18n.t("discussion_bridge_ghost.comments.discussion"),
      }
    end

    private

    def public_topic(url, origin)
      ConnectionCheck.require_receiver!
      return unless SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled &&
        !SiteSetting.login_required && url.is_a?(String) && origin.present?

      canonical = ::DiscussionBridge::CanonicalSource.call(connection_id: "ghost-public-comments", source_url: url).source_url
      uri = URI.parse(canonical)
      return unless uri.is_a?(URI::HTTPS) && uri.origin == origin

      bindings = DiscussionBridgeContentBinding.joins(:content_connection, :bridge_record).where(
        canonical_url: canonical, state: "active",
        discussion_bridge_content_connections: { platform: "ghost", enabled: true },
        discussion_bridge_bridge_records: { state: "healthy" },
      ).limit(2).to_a
      return unless bindings.one?

      binding = bindings.first
      connection = binding.content_connection
      record = binding.bridge_record
      configuration = ::DiscussionBridge::CmsConfiguration.current!(connection, required_direction: record.direction)
      return unless configuration.fetch("profile") == "ghost" && connection.allows_lane?(record.lane)
      ::DiscussionBridge::CmsConfiguration.destination_url!(connection, configuration, canonical)
      return unless linked?(binding, record)

      topic = record.topic
      return unless topic && !topic.private_message? && topic.deleted_at.nil? &&
        !SharedDraft.exists?(topic_id: topic.id) && Guardian.new.can_see_topic?(topic)

      topic
    rescue Error, ArgumentError
      nil
    rescue ::DiscussionBridge::CmsProtocol::Error
      nil
    end

    def linked?(binding, record)
      if record.direction == "to_discourse"
        binding.role == "source" && record.cms_source_publication&.fetch("state", nil) == "active"
      elsif binding.role == "presentation" && binding.presentation_mode == "simple"
        DiscussionBridgeCmsMapping.where(content_binding_id: binding.id, mapping_state: %w[active pending])
          .where.not(publicly_verified_source_revision: nil).exists?
      end
    end
  end
end
