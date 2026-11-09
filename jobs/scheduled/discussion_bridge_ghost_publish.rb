# frozen_string_literal: true

module Jobs
  class DiscussionBridgeGhostPublish < ::Jobs::Scheduled
    every 1.minute
    sidekiq_options retry: false

    def execute(_args)
      DiscussionBridgeGhost::AutomaticPublishing.run
    end
  end
end
