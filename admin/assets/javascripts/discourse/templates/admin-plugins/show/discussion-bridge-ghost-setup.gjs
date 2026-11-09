import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";

class GhostDirection extends Component {
  @tracked saved = this.args.direction;
  @tracked enabled = this.saved.enabled;
  @tracked adminUrl = this.saved.admin_url;
  @tracked kind = this.saved.kind;
  @tracked label = this.saved.url_label || "";
  @tracked tag = this.saved.tag || "";
  @tracked credential = "";
  @tracked saving = false;
  @tracked confirmed = false;

  get outbound() {
    return this.args.direction.id === "from_discourse";
  }

  get heading() {
    return this.outbound
      ? "discussion_bridge_ghost.admin.outbound"
      : "discussion_bridge_ghost.admin.inbound";
  }

  get credentialLabel() {
    return this.outbound
      ? "discussion_bridge_ghost.admin.admin_key"
      : "discussion_bridge_ghost.admin.content_key";
  }

  get needsCredential() {
    return !this.saved.credential_saved || this.adminUrl.trim() !== this.saved.admin_url;
  }

  @action
  change(field, event) {
    this[field] = field === "enabled" ? event.target.checked : event.target.value;
    this.confirmed = false;
  }

  @action
  async save(event) {
    event.preventDefault();
    this.saving = true;
    this.confirmed = false;
    try {
      const { id } = this.args.connection;
      const direction = this.args.direction.id;
      const url = `/discussion-bridge-ghost/admin/connections/${encodeURIComponent(id)}/${direction}.json`;
      const setup = {
        enabled: this.enabled,
        admin_url: this.adminUrl,
        ghost_credential: this.credential,
        ...(this.outbound ? { kind: this.kind, url_label: this.label } : { tag: this.tag }),
      };
      const result = await ajax(url, {
        type: "PUT",
        contentType: "application/json",
        data: JSON.stringify({ setup }),
      });
      this.saved = result.direction;
      this.enabled = this.saved.enabled;
      this.adminUrl = this.saved.admin_url;
      this.kind = this.saved.kind;
      this.label = this.saved.url_label || "";
      this.tag = this.saved.tag || "";
      this.confirmed = true;
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.credential = "";
      this.saving = false;
    }
  }

  <template>
    <form class="form-vertical" {{on "submit" this.save}}>
      <fieldset disabled={{this.saving}}>
        <legend>{{i18n this.heading}}</legend>
        <label>
          <input type="checkbox" checked={{this.enabled}} {{on "change" (fn this.change "enabled")}} />
          {{i18n "discussion_bridge_ghost.admin.enabled"}}
        </label>
        {{#if this.enabled}}
          <div class="control-group">
            <label>
              {{i18n "discussion_bridge_ghost.admin.api_url"}}
              <input type="url" value={{this.adminUrl}} required maxlength="2048" {{on "input" (fn this.change "adminUrl")}} />
            </label>
          </div>
          <div class="control-group">
            <label>
              {{i18n this.credentialLabel}}
              <input
                type="password"
                autocomplete="new-password"
                value={{this.credential}}
                required={{this.needsCredential}}
                maxlength="128"
                {{on "input" (fn this.change "credential")}}
              />
            </label>
            {{#unless this.needsCredential}}
              <p>{{i18n "discussion_bridge_ghost.admin.keep_key"}}</p>
            {{/unless}}
          </div>
          {{#if this.outbound}}
            <div class="control-group">
              <label>
                {{i18n "discussion_bridge_ghost.admin.kind"}}
                <select {{on "change" (fn this.change "kind")}}>
                  <option value="post" selected={{eq this.kind "post"}}>{{i18n "discussion_bridge_ghost.admin.post"}}</option>
                  <option value="page" selected={{eq this.kind "page"}}>{{i18n "discussion_bridge_ghost.admin.page"}}</option>
                </select>
              </label>
            </div>
            <div class="control-group">
              <label>
                {{i18n "discussion_bridge_ghost.admin.url_label"}}
                <input type="text" value={{this.label}} maxlength="191" {{on "input" (fn this.change "label")}} />
              </label>
            </div>
          {{else}}
            <div class="control-group">
              <label>
                {{i18n "discussion_bridge_ghost.admin.tag"}}
                <input type="text" value={{this.tag}} required maxlength="100" {{on "input" (fn this.change "tag")}} />
              </label>
            </div>
          {{/if}}
        {{/if}}
        <button type="submit" class="btn btn-primary">{{i18n "discussion_bridge_ghost.admin.save"}}</button>
        {{#if this.confirmed}}
          <span role="status">{{i18n "discussion_bridge_ghost.admin.saved"}}</span>
        {{/if}}
      </fieldset>
    </form>
  </template>
}

export default <template>
  <h1>{{i18n "discussion_bridge_ghost.admin.title"}}</h1>
  <p>{{i18n "discussion_bridge_ghost.admin.intro"}}</p>
  <p><a href="/admin/plugins/discourse-discussion-bridge/connections">{{i18n "discussion_bridge_ghost.admin.connections"}}</a></p>

  {{#each @controller.model.connections as |connection|}}
    <section>
      <h2>{{connection.name}}</h2>
      <p>{{connection.origin}}</p>
      {{#each connection.directions as |direction|}}
        <GhostDirection @connection={{connection}} @direction={{direction}} />
      {{/each}}
    </section>
  {{else}}
    <p>{{i18n "discussion_bridge_ghost.admin.empty"}}</p>
  {{/each}}
</template>
