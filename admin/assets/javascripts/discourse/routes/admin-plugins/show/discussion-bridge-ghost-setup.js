import Route from "@ember/routing/route";
import { ajax } from "discourse/lib/ajax";

export default class DiscussionBridgeGhostSetupRoute extends Route {
  model() {
    return ajax("/discussion-bridge-ghost/admin/connections.json");
  }
}
