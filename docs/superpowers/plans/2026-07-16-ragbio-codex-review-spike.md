# RagBio Codex Review Integration Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove that the native RagBio macOS app can start, stream, pause, resume, and open artifacts from a local Codex SDK task using the user's ChatGPT/Codex authentication, without opening the Codex application.

**Architecture:** A small TypeScript sidecar uses `@openai/codex-sdk` and speaks a RagBio-owned JSONL protocol over standard input and output. Swift launches the sidecar through an injected `ReviewHelperProcess`, converts helper events into observable connection state, and exposes a temporary Review Engine connection probe in Settings. This spike does not implement the systematic-review workflow; it validates the adapter boundary on which that workflow depends.

**Tech Stack:** Swift 5 language mode, SwiftUI, Swift Testing, macOS 13+, Node.js 18+, TypeScript 5, `@openai/codex-sdk` 0.144.5, Node built-in test runner, JSON Lines, Swift `Process`, `NSWorkspace`.

## Global Constraints

- Do not start execution from the current dirty checkout. Preserve or commit the six existing modified Swift/test files, then create an isolated worktree from the resulting branch tip.
- Do not modify the current AI search, `Use`, Search History, or manual `Export URLs…` behavior during this spike.
- Do not add a server, Platform API key, or RagBio-owned model billing.
- Never read, copy, log, or persist `~/.codex/auth.json`.
- The helper protocol belongs to RagBio and must not expose raw App Server JSON-RPC to SwiftUI.
- Only the probe's working directory may be writable by the Codex run.
- The spike must work with fixture mode without a network connection or Codex login so Swift tests remain deterministic.
- The live verification uses the current arm64 Mac first; x86_64 packaging is explicitly outside this spike.
- Do not commit `node_modules`, generated helper bundles, Codex binaries, fixture `.xlsx`/`.docx` outputs, or user credentials.
- If ChatGPT authentication, subscription-backed execution, or distributable runtime packaging fails, stop after documenting the result; do not begin the production Review Engine.

---

## File Map

### New helper files

- `Tools/ReviewHelper/package.json` — pinned helper dependencies and build/test commands.
- `Tools/ReviewHelper/package-lock.json` — reproducible npm dependency graph.
- `Tools/ReviewHelper/tsconfig.json` — strict Node TypeScript build configuration.
- `Tools/ReviewHelper/src/protocol.ts` — RagBio JSONL command/event types and validation.
- `Tools/ReviewHelper/src/codex-auth.ts` — supported Codex CLI login status and browser-login subprocess.
- `Tools/ReviewHelper/src/codex-runner.ts` — Codex SDK startup, streaming, abort, and resume behavior.
- `Tools/ReviewHelper/src/fixture-artifacts.ts` — minimal valid fixture `.xlsx` and `.docx` creation for end-to-end file handling.
- `Tools/ReviewHelper/src/main.ts` — line-oriented stdin command loop and stdout event writer.
- `Tools/ReviewHelper/test/protocol.test.ts` — deterministic protocol tests.
- `Tools/ReviewHelper/test/fixture-artifacts.test.ts` — validates fixture ZIP containers and expected entries.
- `Tools/ReviewHelper/scripts/build.sh` — builds the helper without writing generated files into the source tree.
- `Tools/ReviewHelper/scripts/assemble-spike-app.sh` — assembles a local `.app` with the spike helper/runtime layout for signing tests.

### New Swift files

- `Sources/RagBio/ReviewHelperModels.swift` — Swift command/event/status models.
- `Sources/RagBio/ReviewHelperProcess.swift` — injectable process abstraction and production `Process` implementation.
- `Sources/RagBio/ReviewHelperClient.swift` — JSONL encoding, incremental decoding, lifecycle, pause, and resume.
- `Sources/RagBio/ReviewConnectionProbe.swift` — observable probe state used only by Settings.
- `Tests/RagBioTests/ReviewHelperClientTests.swift` — protocol, streaming, cancellation, and malformed-event tests.
- `Tests/RagBioTests/ReviewConnectionProbeTests.swift` — connection-state mapping tests.

### Modified files

- `Sources/RagBio/ContentView.swift` — add a temporary `Review Engine Preview` Settings card.
- `.gitignore` — ignore helper build products and probe output.
- `README.md` — document the internal spike command and that it is not the production Review feature.

### Spike evidence

- `docs/review-engine/codex-sdk-spike-results.md` — measured login, subscription, streaming, resume, artifact, size, signing, and recommendation results.

---

### Task 1: Define and Test the RagBio Helper Protocol

**Files:**
- Create: `Tools/ReviewHelper/package.json`
- Create: `Tools/ReviewHelper/package-lock.json`
- Create: `Tools/ReviewHelper/tsconfig.json`
- Create: `Tools/ReviewHelper/src/protocol.ts`
- Create: `Tools/ReviewHelper/test/protocol.test.ts`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: newline-delimited UTF-8 JSON on stdin.
- Produces: `parseCommand(line: string): HelperCommand` and `encodeEvent(event: HelperEvent): string`.
- Later tasks rely on commands `auth.status`, `auth.login`, `probe.start`, `probe.pause`, and `probe.resume`, plus typed auth and probe events.

- [ ] **Step 1: Write the failing protocol tests**

Create tests using `node:test` that assert valid start/resume commands decode, unknown fields are rejected, malformed JSON is rejected without echoing its contents, and every encoded event ends with exactly one newline.

```ts
import assert from "node:assert/strict";
import test from "node:test";
import { encodeEvent, parseCommand } from "../src/protocol.js";

test("parses a fixture probe start command", () => {
  assert.deepEqual(
    parseCommand(JSON.stringify({
      type: "probe.start",
      requestId: "request-1",
      mode: "fixture",
      workingDirectory: "/tmp/ragbio-review-probe",
    })),
    {
      type: "probe.start",
      requestId: "request-1",
      mode: "fixture",
      workingDirectory: "/tmp/ragbio-review-probe",
    },
  );
});

test("rejects unknown command fields", () => {
  assert.throws(() => parseCommand(JSON.stringify({
    type: "probe.pause",
    requestId: "request-1",
    secret: "must-not-pass",
  })), /Invalid helper command/);
});

test("encodes one JSONL event", () => {
  const line = encodeEvent({
    type: "probe.started",
    requestId: "request-1",
    threadId: "thread-1",
  });
  assert.equal(line.endsWith("\n"), true);
  assert.equal(line.endsWith("\n\n"), false);
});
```

- [ ] **Step 2: Run the tests to verify failure**

Run:

```bash
cd Tools/ReviewHelper
npm test
```

Expected: FAIL because `package.json` and `src/protocol.ts` do not exist.

- [ ] **Step 3: Add the pinned Node project and strict TypeScript configuration**

Use `@openai/codex-sdk` version `0.144.5`, TypeScript, `tsx`, `exceljs`, and `docx`. Use Node's built-in test runner through `tsx --test`. Generate and commit `package-lock.json` with `npm install --package-lock-only`.

```json
{
  "name": "ragbio-review-helper",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "engines": { "node": ">=18" },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "test": "tsx --test test/*.test.ts"
  },
  "dependencies": {
    "@openai/codex-sdk": "0.144.5",
    "docx": "9.5.1",
    "exceljs": "4.4.0"
  },
  "devDependencies": {
    "@types/node": "24.10.1",
    "tsx": "4.20.6",
    "typescript": "5.9.3"
  }
}
```

- [ ] **Step 4: Implement closed-union protocol validation**

Define `ProbeStartCommand`, `ProbePauseCommand`, `ProbeResumeCommand`, `HelperCommand`, and `HelperEvent`. Validate the exact allowed key set for each command before returning it. Convert all parse failures into `Error("Invalid helper command")` so input contents and credentials never appear in logs.

```ts
export type ProbeMode = "fixture" | "live";

export type HelperCommand =
  | { type: "auth.status"; requestId: string }
  | { type: "auth.login"; requestId: string }
  | { type: "probe.start"; requestId: string; mode: ProbeMode; workingDirectory: string }
  | { type: "probe.pause"; requestId: string }
  | { type: "probe.resume"; requestId: string; threadId: string; workingDirectory: string };

export type HelperEvent =
  | { type: "auth.status"; requestId: string; method: "chatgpt" | "apiKey" | "signedOut" }
  | { type: "auth.login.started"; requestId: string }
  | { type: "auth.login.completed"; requestId: string; method: "chatgpt" }
  | { type: "probe.started"; requestId: string; threadId: string }
  | { type: "probe.stage"; requestId: string; stage: string; detail: string }
  | { type: "probe.artifacts"; requestId: string; workbookPath: string; manuscriptPath: string }
  | { type: "probe.paused"; requestId: string; threadId: string }
  | { type: "probe.completed"; requestId: string; threadId: string }
  | { type: "probe.failed"; requestId: string; category: "authentication" | "allowance" | "network" | "runtime" | "protocol"; message: string };
```

- [ ] **Step 5: Ignore generated helper and probe files**

Add:

```gitignore
Tools/ReviewHelper/node_modules/
Tools/ReviewHelper/dist/
.build/review-helper/
.build/review-probe/
```

- [ ] **Step 6: Run protocol tests and TypeScript build**

Run:

```bash
cd Tools/ReviewHelper
npm install
npm test
npm run build
```

Expected: all protocol tests PASS and `tsc` exits 0.

- [ ] **Step 7: Commit the protocol boundary**

```bash
git add .gitignore Tools/ReviewHelper
git commit -m "add review helper protocol"
```

---

### Task 2: Build Fixture Mode and Artifact Events

**Files:**
- Create: `Tools/ReviewHelper/src/fixture-artifacts.ts`
- Create: `Tools/ReviewHelper/src/main.ts`
- Create: `Tools/ReviewHelper/test/fixture-artifacts.test.ts`
- Create: `Tools/ReviewHelper/scripts/build.sh`
- Modify: `Tools/ReviewHelper/package.json`

**Interfaces:**
- Consumes: `probe.start` with `mode: "fixture"`.
- Produces: deterministic stage events, a resumable thread ID `fixture-<requestId>`, and valid fixture workbook/manuscript paths.
- Later Swift tests may launch `node Tools/ReviewHelper/dist/main.js` without Codex authentication.

- [ ] **Step 1: Write failing fixture artifact tests**

The workbook must be a valid ZIP container containing `xl/workbook.xml`. The manuscript must contain `word/document.xml`. The command loop must emit stages in this exact order: `prepare`, `extract`, `generate`, `verify`.

```ts
test("creates openable fixture artifacts", async () => {
  const directory = await mkdtemp(join(tmpdir(), "ragbio-review-"));
  const artifacts = await createFixtureArtifacts(directory);
  const workbook = await readFile(artifacts.workbookPath);
  const manuscript = await readFile(artifacts.manuscriptPath);
  assert.equal(workbook.subarray(0, 2).toString(), "PK");
  assert.equal(manuscript.subarray(0, 2).toString(), "PK");
});
```

- [ ] **Step 2: Run tests to verify failure**

Run `cd Tools/ReviewHelper && npm test`.

Expected: FAIL because `createFixtureArtifacts` and the command loop do not exist.

- [ ] **Step 3: Implement minimal valid artifacts**

Create an ExcelJS workbook with `README` and `Source audit` sheets. Create a DOCX with a title and a paragraph stating that it is a connection probe, not a review result. Write both to the supplied working directory and return absolute paths.

```ts
export async function createFixtureArtifacts(directory: string): Promise<ArtifactPaths> {
  await mkdir(directory, { recursive: true });
  const workbookPath = resolve(directory, "Review Probe.xlsx");
  const manuscriptPath = resolve(directory, "Review Probe.docx");
  const workbook = new Workbook();
  workbook.addWorksheet("README").addRow(["RagBio Review Engine connection probe"]);
  workbook.addWorksheet("Source audit").addRow(["Record ID", "Status"]);
  await workbook.xlsx.writeFile(workbookPath);
  const document = new Document({
    sections: [{ children: [
      new Paragraph({ text: "RagBio Review Engine Probe", heading: HeadingLevel.TITLE }),
      new Paragraph("This file verifies local artifact delivery; it is not a systematic review."),
    ] }],
  });
  await writeFile(manuscriptPath, await Packer.toBuffer(document));
  return { workbookPath, manuscriptPath };
}
```

- [ ] **Step 4: Implement the fixture command loop**

Read stdin with `readline.createInterface`. Handle one active request, emit deterministic stages with a short delay, honor `probe.pause`, and on `probe.resume` skip already emitted fixture stages recorded in memory for the current helper process. Keep stdout exclusively JSONL; send diagnostics to stderr without command payloads.

- [ ] **Step 5: Build outside the source tree through one script**

`scripts/build.sh` must run `npm ci`, `npm test`, `npm run build`, then copy only `dist`, `package.json`, `package-lock.json`, and production dependencies into `.build/review-helper/dev`. It must use `set -euo pipefail` and resolve paths relative to the script.

- [ ] **Step 6: Verify fixture mode manually**

Run:

```bash
printf '%s\n' '{"type":"probe.start","requestId":"manual-1","mode":"fixture","workingDirectory":"/tmp/ragbio-review-probe"}' \
  | node Tools/ReviewHelper/dist/main.js
```

Expected: valid JSONL containing four ordered stage events, artifact paths, and `probe.completed`. Both files start with ZIP magic bytes and open with the default macOS applications.

- [ ] **Step 7: Commit fixture mode**

```bash
git add Tools/ReviewHelper
git commit -m "add review helper fixture mode"
```

---

### Task 3: Add Live Codex SDK Streaming and Resume

**Files:**
- Create: `Tools/ReviewHelper/src/codex-auth.ts`
- Create: `Tools/ReviewHelper/src/codex-runner.ts`
- Create: `Tools/ReviewHelper/test/codex-auth.test.ts`
- Create: `Tools/ReviewHelper/test/codex-runner.test.ts`
- Modify: `Tools/ReviewHelper/src/main.ts`

**Interfaces:**
- Consumes: `runLiveProbe(requestId, workingDirectory, threadId?, signal, emit)`.
- Produces: SDK thread ID, normalized stage events, completion, and categorized failures.
- Uses `Codex.startThread` for new work and `Codex.resumeThread` for saved thread IDs.
- Produces: `getAuthStatus()` and `startBrowserLogin()` using the same pinned Codex package/runtime as the SDK.

- [ ] **Step 1: Write failing event-mapping tests with a fake SDK stream**

Map `thread.started` to `probe.started`, selected `item.completed` events to safe stage details, `turn.completed` to completion, `turn.failed` and `error` to categorized failures. Never forward raw reasoning or command output.

```ts
test("maps a streamed thread without leaking reasoning", async () => {
  const events = asyncGenerator([
    { type: "thread.started", thread_id: "thread-1" },
    { type: "item.completed", item: { id: "1", type: "reasoning", text: "private" } },
    { type: "turn.completed", usage: { input_tokens: 1, cached_input_tokens: 0, output_tokens: 1, reasoning_output_tokens: 1 } },
  ]);
  const output = await collectMappedEvents("request-1", events);
  assert.equal(JSON.stringify(output).includes("private"), false);
  assert.equal(output.at(-1)?.type, "probe.completed");
});
```

- [ ] **Step 2: Run the helper tests to verify failure**

Run `cd Tools/ReviewHelper && npm test`.

Expected: FAIL because live event mapping is undefined.

- [ ] **Step 3: Implement the live SDK runner**

Instantiate `Codex` without an API key. Start a thread with `sandboxMode: "workspace-write"`, `workingDirectory`, `skipGitRepoCheck: true`, `networkAccessEnabled: true`, and `approvalPolicy: "never"`. Use `runStreamed()` with an `AbortSignal`.

The probe prompt must be fixed and non-destructive:

```text
You are running the RagBio Review Engine connection probe.
Work only inside the supplied working directory.
Create probe-status.json containing exactly:
{"status":"connected","executor":"codex-sdk"}
Then reply with exactly: RAGBIO_REVIEW_PROBE_OK
```

Record the SDK thread ID from `thread.started`. Categorize errors by conservative message matching: authentication/login/401, allowance/rate limit/429, network, then runtime. Preserve only a short sanitized user message.

- [ ] **Step 4: Implement supported authentication subprocesses**

Resolve the installed `@openai/codex` CLI entry point with `createRequire(import.meta.url).resolve("@openai/codex/bin/codex.js")`. Run it with `process.execPath` rather than a login shell.

- `auth.status` runs `codex login status`, maps only `ChatGPT`, `API key`, or signed-out state, and discards raw output.
- `auth.login` runs `codex login`, emits `auth.login.started`, allows the supported CLI browser flow to open, then reruns status.
- A successful first login must emit `auth.login.completed` only when the resulting method is ChatGPT.
- API-key login is reported but is not accepted as a passing subscription-backed spike result.

Unit tests inject a fake `spawn` function and assert the exact executable/arguments, nonzero-exit mapping, and that raw child output never appears in an emitted event.

- [ ] **Step 5: Implement pause and resume**

`probe.pause` aborts the active turn and emits `probe.paused` with the recorded thread ID. `probe.resume` calls `codex.resumeThread(threadId, options)` and sends the fixed continuation prompt `Continue the RagBio Review Engine connection probe from the existing thread.`

- [ ] **Step 6: Keep stdin responsive while a probe runs**

The readline handler must launch the active probe in a tracked promise without awaiting it inside the line callback. Maintain exactly one `AbortController`. Reject a second `probe.start` with a protocol failure while the first is active, but continue accepting `probe.pause`.

- [ ] **Step 7: Run automated tests**

Run `cd Tools/ReviewHelper && npm test && npm run build`.

Expected: all fake-stream tests PASS; no test contacts OpenAI.

- [ ] **Step 8: Run the authenticated live probe**

Run one live command from a temporary writable directory while logged in through ChatGPT:

```bash
printf '%s\n' '{"type":"probe.start","requestId":"live-1","mode":"live","workingDirectory":"/tmp/ragbio-review-live"}' \
  | node Tools/ReviewHelper/dist/main.js
```

Expected: `probe.started`, safe stage events, `probe.completed`, and `/tmp/ragbio-review-live/probe-status.json` with the exact expected JSON. Confirm no API key environment variable is set for the helper process.

- [ ] **Step 9: Commit live SDK execution**

```bash
git add Tools/ReviewHelper
git commit -m "stream review probe through codex sdk"
```

---

### Task 4: Build the Swift JSONL Client with an Injectable Process

**Files:**
- Create: `Sources/RagBio/ReviewHelperModels.swift`
- Create: `Sources/RagBio/ReviewHelperProcess.swift`
- Create: `Sources/RagBio/ReviewHelperClient.swift`
- Create: `Tests/RagBioTests/ReviewHelperClientTests.swift`

**Interfaces:**
- Produces: `ReviewHelperClient.events(for:) -> AsyncThrowingStream<ReviewHelperEvent, Error>`.
- Produces: `ReviewHelperClient.pause(requestID:) async throws`.
- Consumes: `ReviewHelperProcess` with `start()`, `write(_:)`, `stdoutBytes`, `stderrBytes`, `terminate()`, and `terminationStatus`.
- Later the probe observes only typed `ReviewHelperEvent` values.

- [ ] **Step 1: Write failing incremental JSONL tests**

Cover an event split across byte chunks, multiple events in one chunk, malformed JSON, nonzero process exit, stderr redaction, and cancellation terminating the process. Use an in-memory fake process; never launch Node in unit tests.

```swift
@Test func decodesEventSplitAcrossChunks() async throws {
    let process = FakeReviewHelperProcess(stdoutChunks: [
        Data(#"{"type":"probe.started","requestId":"r1","th"#.utf8),
        Data(#"readId":"t1"}\n"#.utf8)
    ])
    let client = ReviewHelperClient(processFactory: { process })
    let events = try await collect(client.events(for: .fixtureStart(
        requestID: "r1",
        workingDirectory: URL(fileURLWithPath: "/tmp/probe")
    )))
    #expect(events == [.started(requestID: "r1", threadID: "t1")])
}
```

- [ ] **Step 2: Run the focused Swift test to verify failure**

Run:

```bash
swift test --filter ReviewHelperClientTests
```

Expected: FAIL because the Review helper Swift types do not exist.

- [ ] **Step 3: Add Codable command/event models**

Use explicit coding keys and a discriminator-first decoder. Unknown event types must throw `ReviewHelperClientError.unsupportedEvent`, and error descriptions must never include raw JSON.

```swift
enum ReviewHelperEvent: Equatable, Sendable {
    case authStatus(requestID: String, method: ReviewHelperAuthMethod)
    case authLoginStarted(requestID: String)
    case authLoginCompleted(requestID: String)
    case started(requestID: String, threadID: String)
    case stage(requestID: String, stage: String, detail: String)
    case artifacts(requestID: String, workbookURL: URL, manuscriptURL: URL)
    case paused(requestID: String, threadID: String)
    case completed(requestID: String, threadID: String)
    case failed(requestID: String, category: ReviewHelperFailureCategory, message: String)
}
```

- [ ] **Step 4: Implement process abstraction and JSONL client**

The production process implementation launches an explicitly configured helper executable and arguments; it must not invoke a login shell. Incrementally buffer stdout until newline, cap a single line at 1 MiB, decode UTF-8 strictly, and terminate on protocol failure. Capture stderr only for a bounded diagnostic category; do not surface raw stderr to users.

`ReviewHelperProcess` resolves development paths from `RAGBIO_REVIEW_HELPER_NODE` and `RAGBIO_REVIEW_HELPER_SCRIPT` only when both are present. Otherwise it resolves packaged paths relative to `Bundle.main.bundleURL`:

```text
Contents/Resources/ReviewRuntime/node
Contents/Resources/ReviewRuntime/helper/dist/main.js
```

If neither complete layout exists, throw `ReviewHelperClientError.helperUnavailable` before creating a process.

- [ ] **Step 5: Run Swift helper tests and the full suite**

Run:

```bash
swift test --filter ReviewHelperClientTests
swift test
```

Expected: focused tests PASS, then the full existing suite PASS.

- [ ] **Step 6: Commit the Swift adapter boundary**

```bash
git add Sources/RagBio/ReviewHelperModels.swift Sources/RagBio/ReviewHelperProcess.swift Sources/RagBio/ReviewHelperClient.swift Tests/RagBioTests/ReviewHelperClientTests.swift
git commit -m "add swift review helper client"
```

---

### Task 5: Add a Settings Connection Probe and Artifact Opening

**Files:**
- Create: `Sources/RagBio/ReviewConnectionProbe.swift`
- Create: `Tests/RagBioTests/ReviewConnectionProbeTests.swift`
- Modify: `Sources/RagBio/ContentView.swift`

**Interfaces:**
- Produces: `ReviewConnectionProbe.State` values `idle`, `running(stage:detail:)`, `paused(threadID:)`, `blocked(category:message:)`, and `completed(artifacts:)`.
- Consumes: `ReviewHelperClient` events.
- Exposes: `refreshAuthStatus()`, `connectChatGPT()`, `startFixture()`, `startLive()`, `pause()`, `resume()`, `openWorkbook()`, `openManuscript()`, and `showInFinder()`.

- [ ] **Step 1: Write failing state-mapping tests**

Verify ordered event mapping, artifact URLs retained after completion, authentication/allowance categories presented as recoverable blocks, pause retaining the thread ID, and checkpoint reload restoring the paused thread ID and working directory.

- [ ] **Step 2: Run the focused test to verify failure**

Run `swift test --filter ReviewConnectionProbeTests`.

Expected: FAIL because `ReviewConnectionProbe` does not exist.

- [ ] **Step 3: Implement the observable probe**

Inject the client and output root. Store no tokens. Use one task at a time and cancel it in `deinit`. `openWorkbook` and `openManuscript` call `NSWorkspace.shared.open`; `showInFinder` calls `NSWorkspace.shared.activateFileViewerSelecting` with the two artifact URLs.

Persist only this Codable probe checkpoint at `Application Support/RagBio/ReviewProbe/checkpoint.json`, using atomic writes:

```swift
struct ReviewProbeCheckpoint: Codable, Equatable {
    var requestID: String
    var threadID: String
    var workingDirectory: URL
    var status: Status

    enum Status: String, Codable { case running, paused }
}
```

Delete the probe checkpoint after completion or cancellation. Never store authentication data in it.

- [ ] **Step 4: Add the temporary Settings card**

Add `Review Engine Preview` below AI provider settings with:

- Auth status and `Connect ChatGPT` when signed out.
- Current connection state.
- `Run Fixture Probe`.
- `Run Live Codex Probe`.
- `Pause` and `Resume` when applicable.
- `Open Excel`, `Open Word`, and `Show in Finder` after completion.

The card must state: `Connection test only — this does not generate a systematic review.` It must not expose helper paths, auth paths, or raw SDK output.

- [ ] **Step 5: Run tests and launch the app**

Run:

```bash
swift test
swift build
.build/arm64-apple-macosx/debug/RagBio
```

Expected: all tests PASS; both fixture artifacts open from Settings; the live probe completes without opening the Codex app.

- [ ] **Step 6: Verify pause and process restart manually**

Start a live probe, pause after `probe.started`, record the displayed thread ID, terminate and relaunch RagBio, and resume using the persisted probe checkpoint. Expected: the helper calls `resumeThread`, the task completes, and the already recorded thread is reused rather than creating a new thread.

- [ ] **Step 7: Commit the native probe UI**

```bash
git add Sources/RagBio/ContentView.swift Sources/RagBio/ReviewConnectionProbe.swift Tests/RagBioTests/ReviewConnectionProbeTests.swift
git commit -m "add review engine connection probe"
```

---

### Task 6: Verify First Login and Runtime Distribution Feasibility

**Files:**
- Create: `Tools/ReviewHelper/scripts/inspect-runtime.sh`
- Create: `Tools/ReviewHelper/scripts/assemble-spike-app.sh`
- Create: `docs/review-engine/codex-sdk-spike-results.md`
- Modify: `README.md`

**Interfaces:**
- Produces: a pass/fail decision for browser login, cached subscription-backed execution, runtime size, helper launch, signing, and notarization feasibility.
- No later production task may start unless the result document says `Recommendation: proceed with local SDK adapter`.

- [ ] **Step 1: Add a safe runtime inspection script**

The script must print versions, architectures, file sizes, dynamic-library dependencies, and signature status for Node, the helper, and the pinned Codex binary. It must never print environment variables or credential paths.

Required commands include:

```bash
node --version
file "$CODEX_BINARY"
du -sh "$CODEX_RUNTIME_ROOT"
codesign --verify --deep --strict --verbose=2 "$CODEX_BINARY"
codesign -dv --verbose=4 "$CODEX_BINARY"
otool -L "$CODEX_BINARY"
```

- [ ] **Step 2: Assemble a deterministic local spike app**

`assemble-spike-app.sh` creates `.build/review-spike/RagBio.app` with:

```text
Contents/MacOS/RagBio
Contents/Info.plist
Contents/Resources/ReviewRuntime/node
Contents/Resources/ReviewRuntime/helper/dist/main.js
Contents/Resources/ReviewRuntime/helper/node_modules/
Contents/Resources/ReviewRuntime/codex/
```

Build RagBio with `swift build`, copy the exact executable reported by `swift build --show-bin-path`, copy the current Node executable, run the helper build, and copy production `node_modules`. Copy the pinned arm64 Codex runtime installed under `Tools/ReviewHelper/node_modules/@openai/codex-*` without following paths outside that package. Generate an Info.plist with bundle identifier `com.local.RagBio.ReviewSpike`, executable `RagBio`, and minimum system version `13.0`.

The script must remove only its own `.build/review-spike` output directory before rebuilding. It must not write generated binaries under `Sources/`, `Tools/`, or Git-tracked directories.

- [ ] **Step 3: Test first login with an isolated Codex home**

Use a new temporary `CODEX_HOME` containing no credentials and launch `.build/review-spike/RagBio.app`. From its Settings card, click `Connect ChatGPT` so the helper starts the supported `codex login` browser flow from the same pinned runtime the SDK will use. Confirm:

1. RagBio can present `Connect ChatGPT` without opening the Codex application.
2. The browser returns control successfully.
3. `codex login status` reports ChatGPT authentication.
4. A live SDK probe succeeds using that isolated home.
5. No Platform API key is supplied.

Delete the temporary test account state after recording pass/fail; do not copy it into the repo.

- [ ] **Step 4: Measure bundled and on-demand runtime options**

Record exact installed and compressed sizes for:

- TypeScript helper plus Node runtime.
- Pinned arm64 Codex runtime.
- Combined helper/runtime.

Test two launch layouts without committing binaries:

1. Runtime adjacent to the app bundle helper resources.
2. Runtime downloaded into `Application Support/RagBio/ReviewRuntime/<version>` and verified before launch.

The result document must select one approach based on working login, signature validity, launch behavior, update strategy, and user-visible download size. Do not select solely by implementation convenience.

- [ ] **Step 5: Perform local signing verification**

Ad-hoc sign the assembled spike app and nested executables in inside-out order, then run:

```bash
codesign --verify --deep --strict --verbose=2 .build/review-spike/RagBio.app
spctl --assess --type execute --verbose=4 .build/review-spike/RagBio.app
```

Expected: `codesign` succeeds. Record the actual `spctl` result and whether Developer ID/notarization requires additional packaging work. Do not claim notarization passed unless an actual notarized artifact is tested.

- [ ] **Step 6: Write the spike result with no undecided fields**

The result document must contain:

- Date, hardware architecture, macOS, Swift, Node, SDK, and Codex versions.
- Authentication method shown by `codex login status`.
- Confirmation that no API key was used.
- Fixture and live event timelines.
- Pause/resume thread IDs and outcome.
- Artifact open results.
- Runtime sizes.
- Code-signing and Gatekeeper results.
- Known licensing/redistribution source links.
- A single recommendation: proceed with local SDK adapter, switch to direct App Server integration, or stop and redesign authentication/distribution.
- Exact failed exit criterion and next action if the recommendation is not to proceed.

- [ ] **Step 7: Update the README with probe commands and scope**

Document how a developer builds the helper, runs fixture tests, launches the Settings probe, and removes probe outputs. State explicitly that the probe is not the user-facing Review feature.

- [ ] **Step 8: Run final verification**

Run:

```bash
cd Tools/ReviewHelper && npm ci && npm test && npm run build
cd ../.. && swift test && swift build
git diff --check
```

Expected: all Node and Swift tests PASS, the app builds, and the diff check is clean.

- [ ] **Step 9: Commit the verified spike evidence**

```bash
git add Tools/ReviewHelper/scripts/inspect-runtime.sh Tools/ReviewHelper/scripts/assemble-spike-app.sh docs/review-engine/codex-sdk-spike-results.md README.md
git commit -m "document codex review integration spike"
```

---

## Completion Gate and Follow-up Plans

This plan is complete only when every technical spike exit criterion has measured evidence. If the recommendation is `proceed with local SDK adapter`, write two subsequent implementation plans before adding the production feature:

1. `RagBio Review Job Foundation` — immutable manifests, shared URL resolution, persistent job store, single-active-job policy, checkpoints, versions, deletion, and Review workspace UI using a deterministic fake engine.
2. `RagBio SR/MA Engine and Deliverables` — bundled workflow assets, source retrieval, classification, extraction, analysis, workbook/manuscript generation, verification, and production Codex prompts.

Those plans must use the actual helper/runtime and authentication behavior proven here. They must not assume an SDK, packaging, or login interface that the spike did not verify.
