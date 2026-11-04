# Pinned native Discourse CI

The local `workflows/discourse-plugin-pinned.yml` is derived from Discourse's
standard plugin workflow, not a reduced replacement test harness:

- Source repository: `discourse/.github`.
- Source path: `.github/workflows/discourse-plugin.yml`.
- Source commit: `bee9ee78c8e6fd574a8496f415e08c6eb412d3df`.
- Source bytes: 19,332; SHA256
  `21aa6359b69b64027ff974b7756f01aa845b6ba1e800085fcb772448cf72465f`.
- Upstream author declaration: Discourse.
- Upstream license declaration: `GPL-2.0-only`, from that same commit's
  `package.json`. The derived CI workflow retains that license. The full GNU
  GPL version 2 text is included in the repository's `LICENSE`.

DiscussionBridge modified this CI-only work on 2026-11-03. Checkout, cache and
artifact actions now use fixed commits. Core must be a full commit, without the
upstream compatibility-branch override or a `latest` default. The caller must
provide the fixed container; mutable image fallbacks are removed. The required
receiver is explicitly checked out at commit
`685eb3c6be54b8ef41b68949867b884703e2768e`, before dependency/application setup,
and actual source/Core/receiver checkout identities are checked. The receiver's
native RSpec HEAD assertions remain an additional independent check.
Bundler is frozen so CI cannot silently resolve a replacement dependency lock.

The old `about.json.tests.requiredPlugins` branch declaration is removed because
upstream cloning accepts branches, not a checkout commit, and then runs
`plugin:pull_compatible`. That can change a dependency after cloning. The required
receiver is NOT removed from native CI: its pinned checkout replaces that action.
No private SSH key, compatibility pull or mutable dependency branch is used.

The standard linting, test discovery, backend, annotations, frontend and system
test paths remain. No test type is disabled. Current source has backend and
annotation tests; future frontend/system tests still enter the matrix. A future
browser-capable image or dependency update requires a new explicit pin and tests.

This pins the declared action/dependency roles; it is not a claim that GitHub's
hosted runner or external registry availability is fully hermetic. Current native
runs still use synthetic Ghost HTTP, not live Ghost or installed qualification.
No runtime plugin license, protocol, host requirement or installed environment
is changed by this CI configuration. Original runtime-code notices remain.
