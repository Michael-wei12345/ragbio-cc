# RagBio Codex Review Integration Spike Results

**Date:** 2026-07-16

**Branch:** `codex/review-engine-spike`

**Recommendation:** proceed with local SDK adapter

## Decision

RagBio can host a local Review Engine without a RagBio server or a RagBio-owned OpenAI API key. The tested boundary is a small TypeScript helper using the Codex SDK, launched by the native Swift app through a private JSONL protocol. The helper can reuse a local ChatGPT/Codex login, stream sanitized progress, pause, resume the same Codex thread from a new helper process, and return Excel and Word artifact paths to Swift.

Use the local SDK adapter for the first production implementation. Keep the JSONL protocol owned by RagBio so the Swift UI does not depend on raw App Server events. Do not replace the adapter with direct App Server integration yet: OpenAI documents App Server as the deeper rich-client interface, while recommending the SDK for programmatic jobs and application integration. The adapter preserves that migration path without committing the app UI to either protocol.

For the first signed beta, bundle the arm64 Node and pinned Codex runtime beside the helper inside the app. This is the only tested layout that gives a single-install experience and keeps every executable inside one signing/notarization unit. An Application Support layout also launched successfully, but it would require a separately signed, integrity-checked downloader and update lifecycle. Revisit on-demand delivery only if the measured 160 MB compressed download becomes unacceptable.

## Test environment

| Item | Measured value |
| --- | --- |
| Hardware architecture | Apple silicon (`arm64`) |
| macOS | 26.5.2 (25F84) |
| Swift | Apple Swift 6.3.3, Swift 5 language mode |
| Node runtime | 24.14.1 official darwin-arm64 binary |
| `@openai/codex-sdk` | 0.144.5 |
| Pinned Codex runtime | 0.144.5, arm64 |
| Existing authentication | ChatGPT subscription login |
| Platform API key | Not supplied; the live helper removes OpenAI/Codex API-key environment variables before starting the SDK |

## What passed

### Helper and native boundary

- The helper accepts a closed set of JSONL commands and rejects unknown fields without echoing the input.
- Standard output contains only RagBio-owned events. Raw Codex commands, reasoning, and errors are not forwarded to Swift.
- Swift launches the helper through an injectable `Process` boundary, decodes incremental JSONL events, and maps them to observable connection state.
- A malformed event, helper exit, cancellation, pause, or authentication failure produces a bounded RagBio status rather than exposing helper output.
- The full Swift suite passed with 112 tests in 9 suites. The helper suite passed with 14 Node tests.

### Fixture and artifacts

Fixture mode emitted this deterministic timeline:

1. `prepare` — prepare the local review workspace.
2. `extract` — read the fixture source manifest.
3. `generate` — create the workbook and manuscript.
4. `verify` — verify both artifacts.

The generated `.xlsx` is a valid Open XML spreadsheet containing `xl/workbook.xml`; the `.docx` is a valid Open XML document containing `word/document.xml`. macOS Launch Services recognized them as `org.openxmlformats.spreadsheetml.sheet` and `org.openxmlformats.wordprocessingml.document`, and `open` accepted both with their default applications.

Fixture pause/resume also passed. A resumed fixture skipped stages already emitted by the active helper instead of starting over.

### Live ChatGPT-backed probe

- `codex login status` was normalized to `chatgpt` without reading or copying `~/.codex/auth.json`.
- A live SDK run completed using the existing ChatGPT login and created the exact probe payload `{"status":"connected","executor":"codex-sdk"}`.
- Starting a new helper process and resuming thread `019f6bcb-49d0-7b43-abf4-af1bcd9485b9` completed successfully.
- A separate pause/restart/resume test reused thread `019f6bcc-70a5-7862-9945-fd36b83a4b4a` and completed successfully.
- The fully packaged app runtime also completed a live probe on thread `019f6bd9-c39d-7c00-bf6e-d443d3197d27`.
- The Codex desktop app did not need to be opened for any of these runs.

OpenAI's current authentication documentation describes ChatGPT sign-in as subscription access and API-key sign-in as separately billed usage-based access. Its Codex SDK documentation explicitly supports integrating Codex in an application and resuming a past thread by ID:

- [Codex authentication](https://developers.openai.com/codex/auth/)
- [Codex SDK](https://developers.openai.com/codex/sdk/)
- [Codex App Server](https://developers.openai.com/codex/app-server/)

### Persistence behavior

The temporary Settings probe persists only the request ID, Codex thread ID, working directory, and paused status. Relaunch restores a paused checkpoint and never auto-resumes a paid/long-running operation. It does not persist prompts, raw model events, credentials, or artifact contents in the checkpoint.

## Distribution measurements

| Component | Installed size |
| --- | ---: |
| Official Node binary | 113 MB |
| Helper, production dependencies, and compiled JavaScript | 43 MB |
| Pinned arm64 Codex runtime | 296 MB |
| Combined `ReviewRuntime` | 452 MB |
| Complete spike app | 459 MB |
| Zipped spike app | 160 MB |

The Homebrew Node executable was rejected as a distribution candidate because it links to multiple `/opt/homebrew` libraries. The official Node arm64 binary links only to Apple/system libraries and carries the Node Foundation Developer ID signature.

Both tested runtime locations worked:

- Adjacent bundle resources: fixture and live SDK probe passed.
- `Application Support/RagBio/ReviewRuntime/<version>`: copied runtime signature checks and fixture launch passed.

The Application Support result proves the helper can support an on-demand layout later; it does not implement or approve a production runtime downloader.

## Signing, Gatekeeper, and release work

Nested Mach-O executables were ad-hoc signed inside-out, followed by the RagBio executable and app bundle. `codesign --verify --deep --strict` passed. `spctl --assess --type execute` rejected the app because it has an ad-hoc signature, no Team ID, and no notarization ticket.

This is an expected spike result, not a notarization pass. A distributable build still needs:

1. A Developer ID Application certificate and consistent signing of every nested executable.
2. Hardened runtime and the final entitlements audit.
3. Apple notarization and stapling of the shipped app or disk image.
4. A bundled third-party notices file.
5. Verification on a clean Mac without development tools.

## First-login acceptance gate

Reusing an existing ChatGPT login passed. The supported pinned-runtime browser-login flow also starts from a clean temporary `CODEX_HOME` and presents the OpenAI authorization page without opening the Codex application. Completion of that browser authorization is a manual acceptance test because it requires the user to approve the login.

**Release gate:** before calling the production feature ready, complete one clean-machine login from RagBio Settings, confirm `codex login status` reports ChatGPT, then run one live probe with no API-key environment variables. Do not ship a workaround that copies an existing credential store.

This manual gate does not change the adapter recommendation: existing-login subscription execution, the exact login command, the browser handoff, and packaged-runtime execution are independently verified. It limits the current claim to a technically viable developer spike, not a release-ready authentication UX.

## Dependency and license audit

- OpenAI's Codex repository and SDK are published under Apache License 2.0. Redistribution requires including the license and retaining applicable notices: [OpenAI Codex license](https://github.com/openai/codex/blob/main/LICENSE).
- Node.js permits redistribution under its license and includes third-party licenses that must travel with the binary: [Node.js license](https://github.com/nodejs/node/blob/main/LICENSE).
- `npm audit --omit=dev` reports two moderate advisories and no high or critical advisories. Both originate from ExcelJS 4.4.0 through `uuid` (`GHSA-w5hq-g745-h8pq`). The probe never supplies a caller-owned UUID buffer, but production must not waive the advisory silently. Before release, replace/upgrade the workbook implementation or document a reviewed non-reachable exception with a regression test.
- This audit records engineering constraints; it is not legal advice. A production build must generate and ship a complete license/NOTICE inventory for every bundled npm and binary dependency.

## Exact next action

Write the `RagBio Review Job Foundation` implementation plan using the tested helper protocol, bundled arm64 runtime, explicit user start, persisted paused checkpoints, immutable input manifests, and deterministic fake-engine artifacts. Keep the current manual `Export URLs…` behavior unchanged. Before public distribution, close the clean-login, dependency-advisory, Developer ID, notarization, and clean-Mac acceptance gates above.
