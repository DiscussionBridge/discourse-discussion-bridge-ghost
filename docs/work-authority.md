# Current work authority and renewal recovery

Development implementation only. No native Ghost command, job, controller or
public endpoint is activated by these helpers.

`ExecutionContext` binds a run to its installation, exact native-target advisory
lock, current configuration revision, own-site Rack transport and pinned wire
validator. The historical binding retains the same `ghost-journal-identity-1`
bytes/fields already used by the mutation journal. Credentials are not part of
that binding. A new run after same-identity credential rotation may resolve an
old exact request; a running writer stops when its configuration changes.

`WorkAuthority` is for From Discourse work, not a prerequisite for ordinary
Ghost-to-Discourse delivery. It retains an encrypted checkpoint per work UUID
and lease generation. It compares the actual current connection, mapping and
work; typed JSON alone grants no authority. The publishing policy must remain
enabled for both publish and withdraw actions. Selection/eligibility changes
may authorize an owned withdrawal under an enabled policy. Disabling publishing
does not silently unpublish content or authorize a withdrawal bypass.

Before each guard succeeds, a new V4-15 request proves the retained token through
the actual V4 router. Its operation key and mutation ID are committed before
journal preparation/dispatch. An interrupted renewal resumes those exact bytes.
A completed replay first resolves history, then a separate fresh renewal is
required. Refusal does not mint another mutation; transient responses preserve
their journal cooldown. The checkpoint advances only with a matching successful
Lease, in the same short transaction as the mapping's generation fence.

The mapping fence survives a new work UUID or attempt cycle. A lower generation,
or a different work identity reusing the same generation, cannot write. Existing
request/response receipts remain immutable; the checkpoint is not a replacement
for them. Public URLs, resource/source/external/mapping identities and mode are
compared, not silently rebound. Later explicit URL-management orchestration must
retain its separately verified movement rules.

Restored checkpoint values must retain their exact nullable object types and
counter/last-lease relationship. Every stored fence identity is validated even
when its generation is older than the incoming work. A missing fence is not
treated as first use when a completed local checkpoint or already-owned native
baseline proves earlier execution. These inconsistencies stop for reconciliation;
the helper does not repair rows, reset counters or manufacture empty history.
This check is mapping-wide: an older work UUID's successful checkpoint also
contradicts first use, even while the native ID is still null. Historical records
are validated against their own retained identity, authority, original scope and
URL, not rewritten to the incoming work.

Connector-owned operational records have a nullable public mapping UUID locator
and an index on installation/kind/locator. New work/fence rows set it on creation;
normal updates cannot rebind it. The locator is not authorization and must agree
with the encrypted identity whenever read. Ordinary missing-fence lookup reads
only matching indexed history plus legacy NULL locators, in 100-row batches.
Legacy ciphertext and locator values remain unchanged: there is no automatic
backfill, repair, counter reset or new history. Ambiguous malformed legacy rows
stop for reconciliation. Valid history for a different mapping does not imply
that this mapping's fence is missing. Fresh current receiver proof remains
required after any legitimate first-use or never-successful predecessor path.

The guard requires the operation stage: native mutation only while `leased`;
public verification only while `synchronized`, with the native ID supplied from
the retained native intent/receipt. A newly synchronized mapping is not an
opportunity to adopt an arbitrary object. The original pre-create native-ID
baseline remains retained across restart. Terminal/retry/attention history is
not new write authority. Historical ACK replay belongs to settlement/recovery,
not this active-write guard.

Expiry is absolute UTC on the same Discourse host, never a restart-reset TTL.
After the final fresh reads the guard requires at least 15 seconds remaining,
covering the bounded 10-second Ghost HTTP envelope plus margin. No database
transaction spans a Rack or Ghost request.

A lease and PostgreSQL advisory lock are not a distributed transaction with
Ghost. A native request may have been accepted even if a post-guard or response
fails. The forthcoming durable native intent/apply/recovery layer must retain
that UNKNOWN outcome and reconcile it before another write; these helpers do
not prove a failed create was absent or authorize a second create. Native writes,
public proof, coordinators, installation and complete behavior remain unqualified.
