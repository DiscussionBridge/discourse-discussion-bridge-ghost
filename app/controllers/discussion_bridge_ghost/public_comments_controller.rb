# frozen_string_literal: true

module DiscussionBridgeGhost
  class PublicCommentsController < ::ApplicationController
    requires_plugin "discourse-discussion-bridge-ghost"
    skip_before_action :check_xhr, only: :loader
    # The static script is intentionally embedded by Ghost on another origin.
    skip_before_action :verify_authenticity_token, only: :loader

    LOADER = File.binread(File.expand_path("../../../public/comments.js", __dir__)).freeze
    PublicLink = Data.define(:binding, :topic, :identity)

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

      link = authorized_link(canonical)
      return unless link

      return unless RateLimiter.new(nil, "discussion_bridge_ghost_comments_#{request.remote_ip}", 30, 1.minute).performed!
      return unless current_native_page?(link, canonical)

      # The network check can outlast a configuration, binding, or visibility change.
      confirmed = authorized_link(canonical)
      confirmed.topic if confirmed && confirmed.binding.id == link.binding.id &&
        confirmed.topic.id == link.topic.id && confirmed.identity == link.identity
    rescue Error, ArgumentError
      nil
    rescue ::DiscussionBridge::CmsProtocol::Error
      nil
    end

    def authorized_link(canonical)
      return unless SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled &&
        !SiteSetting.login_required

      bindings = DiscussionBridgeContentBinding.joins(:content_connection, :bridge_record).where(
        canonical_url: canonical, state: "active",
        discussion_bridge_content_connections: { platform: "ghost", enabled: true },
        discussion_bridge_bridge_records: { state: "healthy" },
      ).limit(2).to_a
      return unless bindings.one?

      binding = bindings.first
      connection = binding.content_connection
      record = binding.bridge_record
      outbound = record.direction == "from_discourse"
      configuration = ::DiscussionBridge::CmsConfiguration.current!(
        connection, required_direction: record.direction, require_enabled: outbound,
      )
      return unless configuration.fetch("profile") == "ghost" &&
        configuration.dig("native_capabilities", "publication_kind") == "dynamic" &&
        configuration.fetch("publication_lane") == record.lane && connection.allows_lane?(record.lane)
      ::DiscussionBridge::CmsConfiguration.destination_url!(connection, configuration, canonical)

      topic = record.topic
      return unless topic && !topic.private_message? && topic.deleted_at.nil? &&
        !SharedDraft.exists?(topic_id: topic.id) && Guardian.new.can_see_topic?(topic)

      if outbound
        return unless configuration.dig("native_capabilities", "complete_content_supported")

        identity = outbound_identity(binding, record, topic, configuration.fetch("policy"))
        PublicLink.new(binding, topic, identity) if identity
      elsif record.direction == "to_discourse" && binding.role == "source" &&
          record.cms_source_publication&.fetch("state", nil) == "active"
        PublicLink.new(binding, topic, binding.external_id)
      end
    end

    def outbound_identity(binding, record, topic, policy)
      return unless binding.role == "presentation" && binding.presentation_mode == "simple" &&
        policy.fetch("presentation_mode") == "simple" && policy.fetch("author_ids").empty? &&
        policy.fetch("taxonomy_ids").empty? && ::DiscussionBridge::CmsConfiguration.eligible?(topic, policy)

      mapping = DiscussionBridgeCmsMapping.find_by(content_binding_id: binding.id, mapping_state: %w[active pending])
      return unless mapping && mapping.publicly_verified_source_revision.present? && mapping.destination_native_id.present?

      state = PluginStore.get(Publication::STORE, "#{binding.content_connection.public_id}:#{topic.id}")
      return unless state.is_a?(Hash) && state["mapping_id"] == mapping.mapping_id &&
        state["external_id"] == binding.external_id && state["url"] == binding.canonical_url &&
        state["native_id"] == mapping.destination_native_id && state["owner"].present?

      {
        owner: state.fetch("owner"), resource: record.resource_id.to_s,
        native_id: mapping.destination_native_id, revision: mapping.publicly_verified_source_revision,
      }
    end

    def current_native_page?(link, canonical)
      if link.binding.role == "source"
        InboundPublishing.current_source?(link.binding)
      else
        status, html = GhostSite.public_article(canonical)
        status == 200 && PostPresentation.current_page?(html, **link.identity)
      end
    end
  end
end
