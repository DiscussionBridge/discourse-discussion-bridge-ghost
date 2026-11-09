# frozen_string_literal: true

# name: discourse-discussion-bridge-ghost
# about: Connects Ghost to DiscussionBridge in Discourse.
# version: 0.1.0-dev
# authors: DiscussionBridge

require_relative "lib/discussion_bridge_ghost/ghost_site"
require_relative "lib/discussion_bridge_ghost/connection_check"
require_relative "lib/discussion_bridge_ghost/post_presentation"
require_relative "lib/discussion_bridge_ghost/publication"
require_relative "lib/discussion_bridge_ghost/automatic_publishing"

after_initialize do
  require_relative "jobs/scheduled/discussion_bridge_ghost_publish"
end
