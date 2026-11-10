import { configNavForPlugin } from "discourse/lib/admin-plugin-config-nav";
import { withPluginApi } from "discourse/lib/plugin-api";

export default {
  name: "discussion-bridge-ghost-admin-nav",
  after: "discussion-bridge-admin-nav",

  initialize(container) {
    if (!container.lookup("service:current-user")?.admin) {
      return;
    }

    withPluginApi((api) => {
      const receiver = "discourse-discussion-bridge";
      const receiverNav = configNavForPlugin(receiver);
      if (receiverNav) {
        api.setAdminPluginIcon(receiver, "bridge");
        api.addAdminPluginConfigurationNav(receiver, [
          ...receiverNav.links,
          {
            label: "discussion_bridge_ghost.admin.tab",
            route: "adminPlugins.show.discussion-bridge-ghost",
            description: "discussion_bridge_ghost.admin.setup_description",
          },
        ]);
      }

      api.addAdminPluginConfigurationNav("discourse-discussion-bridge-ghost", [
        {
          label: "discussion_bridge_ghost.admin.setup",
          route: "adminPlugins.show.discussion-bridge-ghost-setup",
          description: "discussion_bridge_ghost.admin.setup_description",
        },
      ]);
    });
  },
};
