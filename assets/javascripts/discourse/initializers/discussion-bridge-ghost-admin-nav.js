import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "discussion-bridge-ghost-admin-nav",

  initialize(container) {
    if (!container.lookup("service:current-user")?.admin) {
      return;
    }

    withPluginApi((api) => {
      api.addAdminPluginConfigurationNav("discourse-discussion-bridge-ghost", [
        {
          label: "discussion_bridge_ghost.admin.setup",
          route: "adminPlugins.show.discussion-bridge-ghost-setup",
          description: "discussion_bridge_ghost.admin.setup_description",
        },
        {
          label: "discussion_bridge_ghost.admin.settings",
          route: "adminPlugins.show.settings",
          description: "discussion_bridge_ghost.admin.settings_description",
        },
      ]);
    });
  },
};
