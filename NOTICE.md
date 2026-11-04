# Source license notices

This connector is GPL-2.0-or-later, as approved by Phil on November 3, 2026.
Its distribution includes the retained notices on reused material below. The
connector's GPL license does not remove those upstream notices.

Ghost adapter material adapted from the existing MIT-licensed
`DiscussionBridge/ghost-discussion-bridge` source retains its MIT notice in
`LICENSES/MIT-Ghost.txt`. This includes the inherited WebSynergetics copyright.

`lib/discussion_bridge_ghost/wire_json.rb` includes exact-number handling adapted
from `DiscussionBridge/discourse-discussion-bridge`, commit
`685eb3c6be54b8ef41b68949867b884703e2768e`,
`lib/discussion_bridge/cms_protocol.rb`. That file is GPL-2.0-or-later; the
receiver's license notice is preserved in `COPYING`. The adapted file is
marked accordingly. Do not treat it as MIT-only code.

Existing Ghost and receiver repositories' licenses are unchanged. No
release or qualified installation package is published.

The separate CI-only `.github/workflows/discourse-plugin-pinned.yml` is derived
from the standard Discourse plugin workflow at
`discourse/.github@bee9ee78c8e6fd574a8496f415e08c6eb412d3df` and retains its
upstream `GPL-2.0-only` license (author declaration: Discourse). Its source,
modifications and license provenance are recorded in
`.github/UPSTREAM_DISCOURSE_CI.md`; full GPL version 2 text is in `LICENSE`.
This does not relicense the connector's independently authored runtime code.
