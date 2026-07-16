# RagBio Review Job Foundation Implementation Plan

## Goal

Turn the current Search History record's complete `Use` ledger into an immutable, persistent Review job and expose a native Review workspace. This phase uses the deterministic local fixture engine; it does not perform systematic-review methodology or consume Codex allowance.

## Product boundary

- `Generate Review` always uses every `Use` paper in the current Search History record.
- Manual `Export Use URLs` remains unchanged.
- Manifest creation and manual export share the same URL resolver and per-record deduplication rules.
- Starting a job freezes its papers and URLs. Later Search History refreshes or `Use` changes cannot mutate it.
- Only one job may run at a time.
- App relaunch converts an interrupted running job to paused and never resumes work automatically.
- Completed outputs remain managed under `Application Support/RagBio/Reviews/<job-id>`.

## Implementation sequence

### 1. Shared source selection and immutable manifest

Create `ReviewManifest.swift` with Codable manifest, paper, skipped-paper, and identity models. Refactor `SearchHistoryExportBuilder` to call one shared `SearchHistoryUseURLSelection` component. Test DOI, PMID, publisher, OpenAlex fallback, ordering, deduplication, missing URLs, and immutability after source records change.

### 2. Persistent job model and store

Create `ReviewJobModels.swift` and an actor-backed `ReviewJobStore.swift`. Store `job.json` and `manifest.json` atomically inside each job directory. Support list, create, update, latest job for a Search History ID, single-running-job enforcement, interrupted-running-to-paused recovery, completed-version preservation, and deletion of incomplete job working state.

### 3. Coordinator and deterministic engine

Create `ReviewJobCoordinator.swift`. It owns confirmation state, starts one fixture helper command, persists every stage transition, maps helper failures to job blocks, copies returned fixture artifacts into managed `outputs/`, and restores paused/completed jobs on launch. It never starts model work automatically.

### 4. Native workspace

Create `ReviewWorkspaceView.swift`. Add `Generate Review` beside `Export Use URLs`, with confirmation showing usable and missing counts. While a job is selected, replace the right detail pane with the Review workspace. Show stage, elapsed time, paper count, pause/resume/cancel controls, and completed artifact actions. Include an explicit `Back to Paper` action.

### 5. Verification

- Unit-test manifest and URL parity.
- Unit-test atomic job persistence, single-running policy, recovery, versioning, and cancellation boundaries.
- Unit-test coordinator event mapping with an injected helper process.
- Run the complete Node helper and Swift suites.
- Build and open a packaged spike app for user acceptance.

## Exit criteria

- The confirmation count exactly matches the frozen manifest.
- A later `Use` change does not change a running or completed job.
- Relaunch shows an interrupted job as paused without helper activity.
- Fixture output opens as valid Excel and Word files.
- Search, Search History, `Use`, Candidate filtering, and manual URL export retain their existing behavior.
