# DiscussionBridge Ghost Connector

Connect a Ghost site from Discourse. Publish selected Discourse topics as
Ghost posts or pages, bring tagged Ghost articles into your forum, and show
their linked discussions in Ghost.

## Connect your Ghost site

1. Install this plugin alongside [DiscussionBridge for Discourse](https://github.com/DiscussionBridge/discourse-discussion-bridge).
2. In **Admin → Plugins → DiscussionBridge → Connections**, configure the
   Ghost Content Connection. Then open the **Ghost** tab.
3. For **Discourse to Ghost**, enter the Ghost API URL and Admin API key.
   Choose posts or pages for new publications.
4. For **Ghost to Discourse**, enter the Ghost API URL and Content API key.
   Choose the Ghost tag to import, and set the destination category and
   author on the connection.

The Ghost tab shows the effective status for each publishing direction.
See the [configuration reference](https://github.com/DiscussionBridge/discourse-discussion-bridge-ghost/blob/v0.4.0-alpha.1.ghost.3/README.md#automatic-publishing)
for the scheduler and how to start with publishing paused.

## Show discussions in Ghost

Add the comments loader to the Ghost article or its theme template. Use the
HTTPS address of your Discourse site.

```html
<script defer src="https://discourse.example.com/discussion-bridge-ghost/comments.js"></script>
```

The loader finds the discussion linked to the article. For topics published
from Discourse, choose Simple, Full, or Interactive on the connection.
[Comments setup and theme options](https://github.com/DiscussionBridge/discourse-discussion-bridge-ghost/blob/v0.4.0-alpha.1.ghost.3/README.md#public-ghost-comments)

V4 Alpha source [`v0.4.0-alpha.1.ghost.3`](https://github.com/DiscussionBridge/discourse-discussion-bridge-ghost/tree/v0.4.0-alpha.1.ghost.3). [Versions and live status](https://docs.discussionbridge.dev/versions-and-live-status/)
