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

Run the same command after a Discourse edit. It keeps the native ID and reserved URL, uses Ghost's `updated_at` write guard, and updates the owned article and Simple snapshot. It verifies the public HTML anonymously before R7 records the source revision as verified. A replay of a verified revision rereads the native article and its public page. [Ghost update semantics](https://docs.ghost.org/admin-api/posts/updating-a-post) and [Ghost routing](https://docs.ghost.org/themes/routing).

## Withdraw and restore

When an owned topic becomes ineligible under the enabled R7 policy, run the same command to process its receiver-issued withdrawal. For example, unlist the topic if the policy excludes unlisted topics. The command changes the owned article to draft. R7 records the withdrawal after the draft readback and an anonymous HTTP 404 or 410 at the reserved URL.

Make the topic eligible again and rerun the command to restore it. The connector verifies the retained draft and republishes the same native article at its reserved URL.

Source feed polling, scheduling, Ghost-to-Discourse publishing, and operator UI are later increments.
