import Route from "@ember/routing/route";
import { service } from "@ember/service";

export default class DiscussionBridgeGhostSetupRoute extends Route {
  @service router;

  beforeModel() {
    this.router.replaceWith(
      "adminPlugins.show.discussion-bridge-ghost",
      "discourse-discussion-bridge"
    );
  }
}
