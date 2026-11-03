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
License: GPL-2.0-or-later; retained reused-material notices are in `NOTICE.md`.

The native-command components remain unactivated: no controller or job calls
them. The development executor sends already-retained ordinary From Discourse
commands under current receiver authority. It can recover a retained successful
response through complete native readback without repeating a write. Only that
checked physical completion releases its temporary exclusion barriers; original
commands, responses and terminal history remain. A completed draft is not a
public publication, ownership receipt or receiver acknowledgment. Unknown writes
without positive completion proof stay blocked. Prepared From writes now require
an exact owned-card operation, a fresh command attribute, preserved ownership
nonce, current native baseline, unrelated editor/metadata preservation and shared
resource/slug/native-ID collision checks. A draft-to-real-ID transition before
receiver binding requires a matching retained physical effect, not a copied ID.
The command attribute does not itself resolve missing-response uncertainty.
URL-move authority, complete source rendering/metadata preparation, no-response
recovery, current/public verification,
coordinators, jobs and administration are still being implemented. Installing
these unfinished components is not a functional replacement adapter.

The authoritative execution order is the existing V4 completion plan; this is
the source component, not a new product work list.
