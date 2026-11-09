import Component from "@glimmer/component";
import { LinkTo } from "@ember/routing";
import { i18n } from "discourse-i18n";

export default class DiscussionBridgeGhostSettings extends Component {
  static shouldRender({ plugin }, { currentUser }) {
    return currentUser?.admin && plugin.id === "discourse-discussion-bridge-ghost";
  }

  <template>
    <LinkTo
      class="btn btn-default btn-text btn-small"
      data-plugin-setting-button="discourse-discussion-bridge-ghost"
      @model="discourse-discussion-bridge"
      @route="adminPlugins.show.discussion-bridge-ghost"
    >
      {{i18n "admin.plugins.change_settings_short"}}
    </LinkTo>
  </template>
}
