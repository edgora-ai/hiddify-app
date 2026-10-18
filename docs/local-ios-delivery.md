# Local iOS delivery and remaining work

This delivery collects the current App, Core and sing-box changes into reviewable fork pull requests. A local iOS package is built only after the reviewed source commits have been merged. Installation, data preservation and network acceptance are separate results.

## Source and review scope

| Repository | Fork | Pull request base |
| --- | --- | --- |
| App | `edgora-ai/hiddify-app` | `main` |
| Core | `edgora-ai/hiddify-core` | `main` |
| sing-box | `edgora-ai/hiddify-sing-box` | `v5` |

The initial local commits were App `98387fe9`, Core `7a6aed4e` and sing-box `da078bc2`. A fresh fetch found newer fork bases: App `f26aadb3`, Core `39d1f4e` and sing-box `5e94a4e6`. Integrations preserve the fork base changes rather than resetting the default branches. Review covers both the resulting pull request diff and the changes introduced by that integration.

Publish from sing-box to Core to App. Each parent must reference the child's actual merged, remotely obtainable commit, including after a squash or merge. The final package must come from a clean checkout of the resulting combination, not a dirty working directory or a previously downloaded Core binary.

The collected changes include:

- Local-profile node management, six-protocol form editing and sharing, reference checks, conflict detection and preservation of untouched fields. Subscription nodes remain read-only.
- An explicit, default-off per-profile fallback-domain option, with DNS association and delivery safeguards in the Core.
- Legacy DNS strategy compatibility, encrypted resolver routing, iOS memory policy, VMess connection-setup lifecycle, UDP sniff-buffer ownership and WebSocket upgrade pre-read handling.
- Bounded, authenticated UDP-stage diagnostics. Adding this API does not establish that a real UDP problem has been fixed.
- iOS platform integration, package identity and an additional import URL scheme.
- The Ping0 contract, bounded capture and offline replay tools under `tool/ping0/`.

Untracked implementation and regression files are part of the review scope. English translation changes are committed separately; ignored generated translations and other generated Dart files are regenerated rather than force-added.

## Verification and merge gates

Review must bind the exact candidate commit. Earlier source summaries are not independent approval. Confirmed code defects are fixed and reviewed again before merge; explicitly deferred network investigations are not silently relabelled as passed.

| Check | Required evidence |
| --- | --- |
| Ping0 tools | Actual standard-library unit-test output and offline replay checks; no live website run is required for this delivery. |
| Local iOS entry points | Pure/fake tests of Makefile and export-option contracts, followed separately by a real package build. Fake success is not a signing or compilation result. |
| Flutter | Node, profile, import and related regression results, plus targeted analysis. |
| Dart to Go | Run the profile fallback test with `--dart-define=HIDDIFY_TEST_GO_BUILDER=true`; its default skip is not a pass. |
| Go | Explicitly selected DNS, memory, connection-lifecycle, buffer, WebSocket and diagnostic API tests, with read-only module requirements and actual tool versions recorded. |
| Independent review | Findings, fixes and re-review for the exact head and cross-repository source combination. |
| Package and install | Actual archive/export, signatures, package identity, fresh backup, installation and post-install data readback. |

The previously excluded one-shot XUDP fixture is not executed or rewritten to run through another entry. Do not run an unrestricted `go test ./...` as a substitute for the reviewed selection. Missing coverage is reported explicitly.

Checks that are absent, skipped or allowed to fail are not proof of success. In particular, upstream workflows do not provide complete iOS pull-request coverage. Fork source checks are deliberately read-only and do not publish artifacts. Preserve the actual local and CI results in the pull request and delivery report.

### Local verification checkpoint — 2026-10-18

Actual standard-library runs against the collected source completed with exit 0:

- `python3 -B -m unittest discover -s tool/ping0 -p 'test_*.py' -v`: 144 tests, OK, including explicit storage-policy validation.
- `python3 -B -m unittest discover -s tool/ios -p 'test_*.py' -v`: 26 tests, OK.
- `python3 -B hiddify-core/scripts/test_ios_local.py`: 10 tests, OK.

These are offline Python/fake-tool results, not Go/Flutter compilation, native dependency provenance, signing or device acceptance. They precede the remaining upstream integrations and must be checked again against the final candidate.

Fixed Go 1.26.3 preparation is currently blocked: the official toolchain-module download timed out, and a separate official-tag source clone reached its deadline before a source commit was obtained. Both failures are retained. The installed Go 1.26.4 is not being represented as the requested package compiler. No new Core bind or App archive has started at this checkpoint.

### Host regression and fork merge checkpoint — 2026-10-19

The following results were read back from complete logs, not inferred from a green badge:

- sing-box PR [#1](https://github.com/edgora-ai/hiddify-sing-box/pull/1) merged as `4a9b51ae38646f5162927d45603e9a2b39e83258`. The reviewed head `0078921e` passed 145 top-level tests and 658 named subtests, with no skips, in [run 39153517303](https://github.com/edgora-ai/hiddify-sing-box/actions/runs/39153517303).
- Core PR [#1](https://github.com/edgora-ai/hiddify-core/pull/1) merged as `9178562f45a9fa6829651219ac52875da24e81a4`, pinning that actual sing-box merge. Its reviewed head `b7528d1` passed 15 top-level tests and 151 named subtests, with no skips, in [run 39154619446](https://github.com/edgora-ai/hiddify-core/actions/runs/39154619446).
- Both jobs used Go 1.26.3 on Linux/amd64 with CGO disabled and an explicit allowlist. Neither job ran the old XUDP fixture, the race detector or Apple code. The deliberately skipped legacy Core publication job is not counted as a test pass.
- App `c8c4f053` passed the updated iOS entry/export contract suite: 40 Python tests, exit 0. These use synthetic files and a fake Flutter executable, not Xcode.

The earlier sing-box run `39151884609` remains a recorded failure: its original 142 tests passed, then libbox failed to link before the three new neighbor tests ran. A separately reviewed change explicitly reproduced the existing production `-checklinkname=0` contract for the libbox test binary; Core's two test binaries require the same contract. This relaxes linkname checks for the entire affected binary, not just one symbol. Passing these tests does not establish private OOM-profiler ABI compatibility, Darwin route-socket behavior or native binding compatibility.

App save/concurrency/retry fixes and the bounded Flutter/Dart-to-Go workflow are undergoing separate review and execution. They are not reported as passing in this checkpoint. The App now pins the actual Core merge rather than a feature-branch SHA.

Local package preparation remains blocked independently of the Linux results. Three fixed Mac Go 1.26.3 acquisition paths failed before a complete SDK was obtained. The corrected private Flutter 3.38.5 SDK reported Dart 3.10.4 successfully, but its first offline, enforced-lockfile App dependency preparation timed out. No local App code generation, new Core bind, archive, signature, backup or installation is claimed from these attempts. The failures and unused native-build allowance are retained; the installed Go 1.26.4 is not substituted for the requested compiler.

### App regression repair checkpoint — 2026-10-19

Two actual Flutter runs remain recorded failures, not successful dependency preparation alone:

- [Run 39156226385](https://github.com/edgora-ai/hiddify-app/actions/runs/39156226385), at `6875d692`, exposed build-time Form notifications and nullable profile-header handling failures.
- [Run 39159787166](https://github.com/edgora-ai/hiddify-app/actions/runs/39159787166), at `7004faff`, passed locked dependency preparation and code generation, then failed the business-test step. The reporter recorded 319 visible successes, 15 hidden loading successes, and 14 errors, without a global completion event. A test passed `BuildContext` where Flutter requires `Element`; configuration commits also recursed through the repository extension and overflowed the stack. Targeted analysis did not run.

Both runs completed the real Dart-to-Go bridge, including the parent Go test, all 12 distinct synthetic saved-profile cases, and successful Go package completion. That individual result is not a complete Flutter-suite pass. The second run does not test later local commits.

The deferred Form update and text-direction fixes, including the corrected effective-direction and `Element` assertions in `2f6893d0`, have independent source review. Repository dispatch repair and a complete run against the final candidate are still required before App merge. No tests are skipped or given longer deadlines to hide the failures.

The offline Python contracts were also run against `2f6893d0`: 144 Ping0-tool tests, 40 iOS-entry tests, and 10 Core-entry tests, each with exit 0. These synthetic, standard-library results do not launch the App, compile an iOS package, exercise signing, or establish device or network acceptance. The local SDK and package-preparation blockers above remain unchanged.

## Local package path

The legacy `ios-libs` target downloads a published Core and can overwrite the local framework. It is not used for this source delivery. The legacy Core preparation also performs unrelated dependency updates and tool installation; the separate `ios-local` entry avoids that path.

The local build uses:

1. Fixed SDK/tool versions and explicit private build, cache, temporary and output directories.
2. A freshly built `HiddifyCore.xcframework` from the merged Core and sing-box sources, with the original feature tags and iOS device target.
3. Locked Flutter dependencies, build-runner generation, slang generation and deployment-mode Pods preparation. A required lock-file change returns to source review rather than being hidden in the final package.
4. Release compilation of `lib/main.dart`, with the driver disabled. Release build mode does not by itself select the production-channel entry point.
5. The parameterized local export options, not the upstream App Store/manual export plist. Export does not upload symbols, change versions automatically, publish a Release or send a package to a store.
6. Verification of the final Runner and tunnel extension build numbers, signatures, provisioning, application identifiers, App Group, Keychain groups, minimum OS and package hash.

The App's local workspace is single-use. The entry refuses existing archive/IPA outputs and atomically claims `.ios-local-attempt` before invoking Flutter. It retains that claim and any outputs after success or failure; changing the build number does not permit a retry. Do not remove the claim or reuse a failed output tree to bypass the approved attempt limit. Flutter 3.38.5 can report exit 0 after archiving even if IPA export fails, so a successful command still requires direct package, plist, signature and hash checks.

Core and App automatic publication workflows are gated away from the delivery forks. Do not create version tags or manually dispatch publishing jobs for this task. An asset named `draft` in the upstream workflow is a public prerelease, not evidence of a private draft.

The local source/compiler/cache manifests and package hashes are retained outside Git. No device identifiers, credentials, profiles, databases, raw network captures or user configuration backups belong in these repositories.

## Data-preserving installation

Installation requires a fresh device window, not an old process identifier or another session's idle state. Keep the currently installed App and extension identity, signing prefix, App Group and data-access entitlements compatible. An identity mismatch is a stop condition, not a reason to uninstall.

Before updating, obtain a current, consistent backup of both the App container and App Group, including SQLite and any required WAL, preferences, source configurations and the original node's complete object. Verify database integrity, query the stored data, read it back and verify it is searchable. A historical backup or a node-name/count check alone is insufficient.

Perform a same-Bundle update without uninstalling, clearing containers, recreating nodes or restoring an older database. After installation, verify the new package identity and compare the actual configuration, preferences and original-node content again. Explain database checkpoint or normal startup differences rather than normalizing away user changes. Launching the App may invoke its existing automatic connection or update settings; preserve those settings and record observed effects.

A successful package installation and readable configuration do not prove that the extension started, a specific node carried the traffic, or UDP/WebRTC passed.

## Deferred investigations

| ID | Remaining question | Current evidence boundary |
| --- | --- | --- |
| NET-01 | Actual iPad DNS-blackhole cause | The complete measured API-zero to submit-zero to server-finding chain is a desktop observation. The matching current iPad chain has not been captured. Resolver count zero is not proof that all system DNS fails or that Fake-IP is the cause. |
| NET-02 | UDP return path and public WebRTC exit | A historical installed build had Core-started, original-node and HTTP-success observations, but public RTC remained unavailable and the UDP return path was not accepted. No current successful result is claimed. |
| NET-03 | Current Core and original-node traffic attribution | Package versions, the system VPN icon and historical selection do not establish the current loaded/selected node or data path. |
| ENV-01 | Browser time zone versus old page result | The most recent system observation was Los Angeles; the browser's current Intl value and the age of an older Shanghai result remain unverified. |
| ENV-02 | iPad Web Inspector availability | The user reported Chrome's switch enabled; the device service still returned a disabled signal. This blocks observation, not proof of a VPN defect or user misconfiguration. |
| ENV-03 | Chinese-font finding interpretation | Apple CJK font support is normal. Font matching alone does not establish nationality, a Chinese system setting or VPN failure. No font spoofing is part of this delivery. |
| PROV-01 | Earlier diagnostic build closure | The retained a3 diagnostic artifact has incomplete native provenance, and an earlier read-only preflight has an unknown terminal state. Those records and consumed attempts remain unchanged; the new package cannot inherit a fabricated success from them. |

These are recorded follow-up items, not promises that merging or installing this delivery resolves them. Report source merge, build, signature, installation, data preservation and App smoke test independently from network acceptance.
