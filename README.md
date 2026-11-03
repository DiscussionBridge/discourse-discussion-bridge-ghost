# DiscussionBridge for Ghost — native Discourse connector

Unfinished V4 development candidate. Not released, installable/qualified or a
replacement for an operator's running adapter yet.

This optional Discourse plugin will run Ghost-specific adapter work inside the
existing Discourse installation. It does not run a separate Node daemon, install
a service/port or modify Ghost core. The shared DiscussionBridge receiver and
V4 protocol remain a separate, platform-neutral dependency.

Both Ghost-to-Discourse and Discourse-to-Ghost behavior, native ownership,
durable identities, exact request/receipt recovery, public assets and native
operator controls must be qualified before installation. Existing Ghost and old
adapter environments remain unchanged during development.

Family/component version: `0.4.0-alpha.1`; protocol: `v4`; release: none.

The authoritative execution order is the existing V4 completion plan; this is
the source component, not a new product work list.
