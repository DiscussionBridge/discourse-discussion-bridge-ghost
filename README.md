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

## Publish or refresh one post

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

Run the same command after a Discourse edit. It keeps the native ID and reserved URL, uses Ghost's `updated_at` write guard, and updates the owned article and Simple snapshot. It verifies the public HTML anonymously before R7 records the source revision as verified. A replay of a verified revision rereads the native post and its public page. [Ghost update semantics](https://docs.ghost.org/admin-api/posts/updating-a-post) and [Ghost routing](https://docs.ghost.org/themes/routing).

This entry point is scoped to posts. Source feed polling, scheduling, pages, withdrawal and restore, Ghost-to-Discourse publishing, and operator UI are later increments.
