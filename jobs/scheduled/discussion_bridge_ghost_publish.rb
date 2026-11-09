# frozen_string_literal: true

module Jobs
  class DiscussionBridgeGhostPublish < ::Jobs::Scheduled
    CADENCE_KEY = "discussion_bridge_ghost:sync_interval"

    every 1.minute
    sidekiq_options retry: false

    def execute(_args)
      return unless defined?(::DiscussionBridge::CmsRecordStore) &&
        SiteSetting.discussion_bridge_enabled && SiteSetting.discussion_bridge_endpoint_enabled

      interval = SiteSetting.discussion_bridge_ghost_sync_interval_minutes.minutes.to_i
      return unless Discourse.redis.set(CADENCE_KEY, "1", nx: true, ex: interval)

      DiscussionBridgeGhost::AutomaticPublishing.run
      DiscussionBridgeGhost::InboundPublishing.run
    end
  end
end
