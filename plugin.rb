# frozen_string_literal: true

# name: discourse-discussion-bridge-ghost
# about: Connects Ghost to DiscussionBridge in Discourse.
# version: 0.1.0-dev
# authors: DiscussionBridge

require_relative "lib/discussion_bridge_ghost/ghost_site"
require_relative "lib/discussion_bridge_ghost/connection_check"
require_relative "lib/discussion_bridge_ghost/post_presentation"
require_relative "lib/discussion_bridge_ghost/publication"
require_relative "lib/discussion_bridge_ghost/orphan_containment"
require_relative "lib/discussion_bridge_ghost/supervised_scope"
require_relative "lib/discussion_bridge_ghost/automatic_publishing"
require_relative "lib/discussion_bridge_ghost/inbound_publishing"
require_relative "lib/discussion_bridge_ghost/admin_setup"
require_relative "lib/discussion_bridge_ghost/packaged_plugin_metadata"

add_admin_route("discussion_bridge_ghost.admin.title", "discourse-discussion-bridge-ghost", use_new_show_route: true)
Rails.application.config.filter_parameters << :ghost_credential

after_initialize do
  require_relative "jobs/scheduled/discussion_bridge_ghost_publish"
  require_relative "app/controllers/discussion_bridge_ghost/admin_connections_controller"
  require_relative "app/controllers/discussion_bridge_ghost/public_comments_controller"

  ::AdminPluginSerializer.prepend(DiscussionBridgeGhost::PackagedPluginMetadata)

  Discourse::Application.routes.append do
    get "/discussion-bridge-ghost/comments.js" => "discussion_bridge_ghost/public_comments#loader"
    get "/discussion-bridge-ghost/comments.json" => "discussion_bridge_ghost/public_comments#show", defaults: { format: :json }
    get "/discussion-bridge-ghost/admin/connections" => "discussion_bridge_ghost/admin_connections#index"
    put "/discussion-bridge-ghost/admin/connections/:id/:direction" => "discussion_bridge_ghost/admin_connections#update"
    get "/admin/plugins/discourse-discussion-bridge-ghost" => "admin/plugins#index", constraints: StaffConstraint.new
    get "/admin/plugins/discourse-discussion-bridge-ghost/*path" => "admin/plugins#index", constraints: StaffConstraint.new
  end
end
