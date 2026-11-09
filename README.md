# DiscussionBridge for Ghost

Development baseline for a Discourse-hosted Ghost connector. The first increment is a read-only connection check. The connector is built against R7 contract `09d77c0209835c2d996aad294d161f167c7bd838` and receiver `685eb3c6be54b8ef41b68949867b884703e2768e`.

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

## First publishing slice

1. Start from a receiver-authorized source intent. Consume V4-06 pages with a durable, connection-scoped checkpoint and stage all page entries before advancing. On a cursor error, retain the exact receiver status and code. Handle scope changes and expired cursors explicitly and reconcile with the mapping inventory.
2. Reserve the initial public URL through V4-09 before taking the work lease or writing to Ghost. Use the native URL default and optional configured label, then retain that reservation through ordinary edits. Establish how the configured Ghost routing can supply a reliable initial URL before enabling writes. A Ghost draft preview URL is independent of that reservation.
3. Claim through V4-13 and assemble and hash-check the immutable content from V4-07. Under a per-publication lock, durably record the exact native intent before dispatch. The Ghost create must bind an ownership marker to the object in the same write. After a lost response, reconcile that marker to one exact object and persist its native ID. If the outcome is ambiguous, record attention and preserve the intent instead of issuing another create.
4. Use the same Ghost native ID and Ghost's `updated_at` write guard for ordinary edits. Only send fields owned by that operation. Keep the slug and editor-managed fields intact. After the native readback, use V4-16 to acknowledge synchronization and then public verification. Public verification uses the reserved URL and verifies the owned rendered article and discussion identity independently of the authenticated Ghost read. [Ghost update semantics](https://docs.ghost.org/admin-api/posts/updating-a-post) and [Ghost routing](https://docs.ghost.org/themes/routing) describe the relevant native behavior.

The first live proof is one post published and edited through the ordinary path with a replay of an interrupted create. Extend that path to a page and to withdrawal and restore after the first proof. Scheduling, incoming Ghost notifications, URL moves, setup UI, and public comments follow the publishing slice.
