# DiscussionBridge for Ghost

Development baseline for a Discourse-hosted Ghost connector. The connector is built against R7 contract `09d77c0209835c2d996aad294d161f167c7bd838` and receiver `685eb3c6be54b8ef41b68949867b884703e2768e`.

## Connection check

In a Discourse Rails console with the connector and pinned receiver loaded, use the public ID of an enabled Ghost Content Connection configured for dynamic publishing. Use the Ghost Admin base URL, including any install subdirectory, and a Ghost Custom Integration key. The Admin URL uses HTTPS and can be on a different domain from the public site.

```ruby
require "io/console"
DiscussionBridgeGhost::ConnectionCheck.call(
  connection_id: "connection-public-id",
  admin_url: "https://admin.example.com",
  admin_key: $stdin.noecho(&:gets).chomp,
)
```

The check verifies the local receiver contract and schema identities, confirms the Ghost site's public origin matches the connection, and uses the key to read from the Admin API's post and page collections. It returns the connection directions, From Discourse policy flag, Ghost version, and the two successful read checks. A success establishes read access only. The [Ghost Admin API reference](https://docs.ghost.org/admin-api) and [site endpoint](https://docs.ghost.org/admin-api/site/overview) describe these interfaces.

## Publish or refresh one post or page

Use the Rails console with a dynamic Ghost connection whose From Discourse policy allows the selected public topic, uses Simple, supports full content, and has no selected author or taxonomy overrides. This slice supports Ghost's default root `/{slug}/` routing and takes an optional `url_label` for the initial slug.

```ruby
require "io/console"
DiscussionBridgeGhost::PublishPost.call(
  connection_id: "connection-public-id",
  topic_id: 123,
  admin_url: "https://admin.example.com",
  admin_key: $stdin.noecho(&:gets).chomp,
)
```

The command uses R7's in-process source lifecycle, mapping, lease, and acknowledgement services. It reserves the URL before creating a draft and saves a unique ownership marker before sending the create. If the create response is lost, repeat the same command. It recovers the draft by exact slug and ownership marker. If it cannot prove ownership, it stops for reconciliation.

Use `DiscussionBridgeGhost::PublishPage.call` with the same arguments to select a page on its first publication. Keep using the same command for that topic and connection. An existing mapping keeps its native type.

Run the same command after a Discourse edit. It keeps the native ID and reserved URL, uses Ghost's `updated_at` write guard, and updates the owned article and its Simple discussion link. It verifies the public HTML anonymously before R7 records the source revision as verified. A replay of a verified revision rereads the native article and its public page. [Ghost update semantics](https://docs.ghost.org/admin-api/posts/updating-a-post) and [Ghost routing](https://docs.ghost.org/themes/routing).

## Withdraw and restore

When an owned topic becomes ineligible under the enabled R7 policy, run the same command to process its receiver-issued withdrawal. For example, unlist the topic if the policy excludes unlisted topics. The command changes the owned article to draft. R7 records the withdrawal after the draft readback and an anonymous HTTP 404 or 410 at the reserved URL.

Make the topic eligible again and rerun the command to restore it. The connector verifies the retained draft and republishes the same native article at its reserved URL.

If the worker loses the result of a first publish and R7 revokes the source before recording the native article ID, R7 puts the mapping into attention without issuing withdrawal work. Keep the ownership journal. An authorized Ghost operator must verify the native ID, owner marker, and article URL before containing the publication. Use the R7 attention record to track reconciliation.

For eligible failed work, use the R7 attention controls to request a check. A scheduled outbound worker inspects the owned Ghost article and reports what it can prove. R7 decides whether a retry is available. When it approves one, the connector claims that specific successor.

## Automatic publishing

Open **Admin → Plugins → DiscussionBridge Ghost → Setup**. Use an enabled Ghost Content Connection configured for R7 in **DiscussionBridge → Connections**. The setup page shows the directions allowed by that connection.

- **Discourse to Ghost.** Enable the direction, enter the Ghost API base URL and Admin API key, and choose posts or pages for new publications. You can add an optional URL label. The connection's R7 From Discourse policy controls the eligible topics. The connector uses Simple presentation and Ghost's default root routing.
- **Ghost to Discourse.** Enable the direction, enter the Ghost API base URL and Content API key, and choose the Ghost tag slug to import. The connection needs a usable author and destination category. Tagged public posts and pages create unlisted topics under the connection's R7 rules. Edits update the original topic. Full article imports must fit the R7 source and request limits. [Ghost Content API](https://docs.ghost.org/content-api)

Save each direction separately. Leave the key field blank to retain the saved key at the same API URL. Enter a new key to replace it or change the API URL. Discourse stores keys encrypted. To disable a direction, clear its checkbox and save.

Set `DISCOURSE_DISCUSSION_BRIDGE_GHOST_SCOPE` in the Discourse service environment before starting the scheduler. An unset or invalid value pauses both directions, as does `paused`. For a supervised install, supply a JSON object with an `outbound` rule containing the approved connection's public `connection_id` and numeric `category_id`, or an `inbound` rule containing those fields and the approved Ghost `tag` slug. R7 public connection IDs use `dbc_` followed by 24 lowercase hexadecimal digits. Include both rules to run both directions. Restart all scheduler processes after changing the scope. For normal operation outside supervision, set it to `unrestricted`. These controls preserve saved connection settings.

Scope the receiver's outbound policy to the test category as well. If an approved source moves outside that policy, scheduled withdrawal can use current R7 work to remove the exact Ghost copy recorded under the same supervised scope.

### Sync interval

In Discourse Admin Site Settings, search for `discussion_bridge_ghost_sync_interval_minutes`. The setting applies to both automatic directions and defaults to 5 minutes. Set it to a value from 1 to 60 minutes. Discourse checks whether a sync is due every minute and uses the new value when the current interval expires.

## Public Ghost comments

For automatic placement, add the following script inside the article in the Ghost theme's post and page templates or in their shared article partial. For a single article, paste it into an HTML card or its Code injection header. Replace the example URL with the HTTPS URL of the Discourse site running this connector. Only articles with a verified R7 discussion display comments.

```html
<script defer src="https://discourse.example.com/discussion-bridge-ghost/comments.js"></script>
```

The loader uses the current Ghost article URL to find its R7 discussion and shows up to 50 guest-visible replies. It supports Ghost articles imported into Discourse and Simple articles published from Discourse. The reader can open the linked topic to join the discussion.

For the Interactive frame, add `data-discussion-bridge-ghost-mode="interactive"` to that article's script tag. The frame opens the linked topic in Discourse's native full app. In Discourse's Embedding settings, allow the Ghost hostname and enable the full app embed. The publication mode on the R7 connection still controls the published article. The script option controls the discussion inside Ghost.

Ghost keeps only the discussion link in new outbound publications. The loader verifies the current Ghost article and gets live replies from Discourse. Outbound live replies require the connection's saved Ghost outbound credential to verify the public article by native ID. When that credential is unavailable, the article retains its discussion link. An earlier connector may have stored replies in the Ghost HTML. If any of those articles are still served, have an authorized operator remove the old reply bodies from Ghost before relying on this loader for moderation.

To choose where the comments appear, put `<div data-discussion-bridge-ghost-comments></div>` in the Ghost theme or article. The loader otherwise uses the existing Simple comments section when present, or adds a section to the article.
