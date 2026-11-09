# frozen_string_literal: true

module DiscussionBridgeGhost
  module PackagedPluginMetadata
    def is_discourse_owned
      return false if ghost_archive?

      super
    end

    def commit_hash
      return if ghost_archive?

      super
    end

    def commit_url
      return if ghost_archive?

      super
    end

    private

    def ghost_archive?
      # Discourse's Git lookup otherwise finds the enclosing Discourse checkout.
      object.name == "discourse-discussion-bridge-ghost" && !File.exist?(File.join(object.directory, ".git"))
    end
  end
end
