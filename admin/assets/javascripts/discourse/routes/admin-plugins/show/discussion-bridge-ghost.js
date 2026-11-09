import Route from "@ember/routing/route";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";

export default class DiscussionBridgeGhostRoute extends Route {
  @service router;

  beforeModel() {
    if (this.modelFor("adminPlugins.show").id !== "discourse-discussion-bridge") {
      this.router.replaceWith(
        "adminPlugins.show.discussion-bridge-ghost",
        "discourse-discussion-bridge"
      );
    }
  }

  model() {
    return ajax("/discussion-bridge-ghost/admin/connections.json");
  }
}
