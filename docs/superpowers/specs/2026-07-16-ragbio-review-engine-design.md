# RagBio Built-in Review Engine Design

Date: 2026-07-16

## Summary

RagBio will turn the papers marked `Use` in the current AI Search History record into a systematic-review data extraction workbook and an English systematic-review manuscript. The workflow will run inside RagBio through a built-in Review Engine backed by a local Codex adapter. Users will not install a Skill, open Codex, copy a URL file, or use a terminal.

The first release targets Mac users with an eligible ChatGPT/Codex account. It will use the user's local ChatGPT/Codex authentication and subscription access. It will not require a RagBio-hosted agent service.

## Product Goals

- Start a review from the current search in one deliberate action.
- Guarantee that the papers processed by the Review Engine exactly match the `Use` selection frozen at task creation.
- Reuse the existing URL export normalization, deduplication, and missing-URL rules.
- Keep task progress, blocking errors, pause/resume controls, and deliverable access inside RagBio.
- Preserve completed work across navigation, app restarts, crashes, and subsequent changes to `Use`.
- Produce a verified `.xlsx` workbook and `.docx` manuscript using the methodology encoded by `sr-ma-from-paper-urls`.

## Non-goals for the First Release

- Supporting users without an eligible ChatGPT/Codex account.
- Running Review jobs on a RagBio cloud service.
- Allowing multiple Review jobs to run concurrently.
- Combining `Use` papers from multiple Search History records in one job.
- Showing an interactive `Review Decisions` screen for inclusion, exclusion, or pooling decisions.
- Requiring routine human confirmation during classification, extraction, or analysis.
- Replacing the existing manual `Export URLs…` capability.

## User Flow

### Starting a Review

1. The current Search History record contains one or more papers marked `Use`.
2. RagBio displays `Generate Review` as the primary action.
3. `Export URLs…` remains available as a secondary menu action.
4. The user clicks `Generate Review`.
5. RagBio builds the proposed input with the same URL resolution and deduplication logic used by manual export.
6. RagBio displays a lightweight confirmation:

   ```text
   Generate Review from 12 papers?
   12 usable URLs · 0 missing URLs
   This task may take some time and use your Codex allowance.

   Cancel                         Start Review
   ```

7. `Start Review` freezes an immutable input manifest and starts the job.
8. The user is not asked to select papers again and no TXT save panel appears.

If there are no `Use` papers, `Generate Review` is disabled with a clear explanation. If only some papers lack usable URLs, confirmation reports the usable and skipped counts. If no selected paper has a usable source, the task cannot start.

### Running a Review

The right-hand content area becomes a persistent Review workspace. The user may continue searching, reading papers, changing filters, and editing other `Use` selections while the Review runs.

The workspace displays real activity rather than a fabricated exact percentage:

- Current workflow stage.
- Current paper title.
- Completed paper count, for example `7 of 12 papers`.
- Completed, active, and pending stages.
- Elapsed time.
- A subtle pulsing status indicator and indeterminate activity animation.

Expected stages are:

1. Preparing sources.
2. Collecting full text and source metadata.
3. Classifying publication and study types.
4. Checking duplicate, companion, interim, and superseded reports.
5. Extracting study data.
6. Assessing study- and analysis-level eligibility.
7. Evaluating risk of bias and certainty.
8. Running appropriate quantitative synthesis.
9. Building the workbook.
10. Writing the manuscript.
11. Verifying both deliverables.

The Review Engine makes its normal methodological decisions automatically. It does not pause to show an Included, Excluded, Background-only, Supplementary, or Not-eligible-for-pooling review screen.

### Completing a Review

The same Review workspace changes to a completed state and shows:

- `Open Excel`
- `Open Word`
- `Save Copies…`
- `Show in Finder`

`Open Excel` and `Open Word` launch the generated files in the user's default applications. RagBio retains its managed copies so the results remain available after the app restarts. `Save Copies…` allows the user to choose another permanent location without moving or invalidating RagBio's managed copies.

The primary action for a Search History record with a completed Review becomes `Open Review`. The latest completed version opens by default. Older versions remain accessible from `… → Previous Reviews`.

## Input Integrity

### Immutable Review Manifest

Starting a Review creates an immutable `ReviewInputManifest`. It contains:

- Review job ID.
- Search History record ID.
- Search query as entered by the user.
- Search snapshot timestamp.
- Manifest creation timestamp.
- Ordered paper inputs.
- Canonical paper identity fields: DOI, PMID, OpenAlex ID, and internal work ID when available.
- Resolved source URL used by the Review Engine.
- Original URL and source metadata.
- Deduplication result.
- Papers skipped because no usable URL was available.

The manifest is the sole source of truth for the running job. Later changes to the search results or `Use` selections do not mutate it.

### Shared URL Resolution

Manual `Export URLs…` and Review manifest creation must call the same URL-selection and normalization component. The system must not maintain separate export and Review implementations. This ensures that the URLs a user could manually export are the URLs sent to the Review Engine for the same frozen selection.

Identity matching prefers stable identifiers in this order when available:

1. Normalized DOI.
2. PMID.
3. OpenAlex ID.
4. Normalized canonical URL.

The manifest preserves both the canonical identity and the actual URL used for retrieval.

## Review Engine Architecture

```text
RagBio SwiftUI
    |
    v
Review Job Coordinator
    |-- manifest and checkpoint storage
    |-- single-active-job policy
    |-- progress events and error mapping
    v
Built-in Review Engine
    |-- source audit and retrieval
    |-- SR/MA workflow rules and bundled assets
    |-- workbook and manuscript orchestration
    v
Codex Adapter
    v
Codex SDK and local Codex runtime
    v
User's ChatGPT/Codex account
```

### Ownership Boundaries

RagBio owns:

- Review job lifecycle and persistent state.
- Input manifests and versions.
- Progress presentation.
- Pause, resume, cancel, and deletion behavior.
- Output file storage and opening.
- User-facing errors.

The built-in Review Engine owns:

- The versioned workflow derived from `sr-ma-from-paper-urls`.
- Source audit, extraction, study classification, and eligibility rules.
- Duplicate and overlapping-report handling.
- Estimand separation and decisions about whether pooling is appropriate.
- Risk-of-bias and GRADE logic.
- Workbook and manuscript structure.
- Deliverable verification.

The Codex adapter owns:

- Starting and resuming Codex work.
- Streaming structured progress events.
- Mapping authentication, allowance, network, and runtime failures into Review job errors.
- Isolating RagBio from Codex SDK and App Server protocol changes.

The SwiftUI views must not communicate directly with App Server JSON-RPC. The first release uses the Codex SDK through the adapter. This keeps the Review Engine replaceable by a future local runtime, API-key adapter, or RagBio-hosted service without rewriting product state or views.

## Authentication and Distribution Boundary

The first release supports ChatGPT/Codex subscription authentication:

- If compatible local Codex credentials exist, RagBio reuses them through the supported Codex runtime behavior.
- If no valid login exists, RagBio presents `Connect ChatGPT` and initiates the supported browser authorization flow.
- After authorization, the Review resumes automatically.
- RagBio never copies credentials into Search History, Review manifests, logs, or output files.
- Logging out or credential expiry moves the task into a recoverable authentication-blocked state.

Before full implementation, a technical spike must verify that the bundled SDK/runtime can perform the intended browser login, reuse cached credentials, consume the user's eligible subscription access, and meet redistribution, signing, and notarization requirements for the RagBio release build.

Users without an eligible ChatGPT/Codex account are outside first-release scope. A future adapter may support platform API billing or a hosted Review service.

## Review Job State

Each job stores:

- Job ID and version number.
- Parent Search History record ID.
- Immutable input manifest.
- Status.
- Current stage.
- Current paper identity.
- Completed paper and stage checkpoints.
- Structured warnings.
- Recoverable blocking error, if any.
- Managed workbook and manuscript paths.
- Created, updated, paused, and completed timestamps.

Supported statuses are:

- `confirming`
- `running`
- `paused`
- `blockedAuthentication`
- `blockedAllowance`
- `blockedSources`
- `failed`
- `completed`
- `cancelled`

Only one job may be `running` at a time. Other searches remain fully usable, but their `Generate Review` action explains that another Review is running. A new job can start after the current job completes, pauses, or is cancelled.

## Checkpoints, Pause, Resume, and Cancellation

The Review Engine writes an atomic checkpoint after every completed paper-level unit and every completed workflow stage. A checkpoint is committed only after its referenced working files are durable.

- Closing the RagBio window while the app remains running does not stop the Review.
- Quitting RagBio pauses the Review at the latest durable checkpoint.
- A crash, network loss, or computer restart restores the latest durable checkpoint.
- RagBio does not automatically resume model usage at app launch.
- The Review workspace shows `Review paused`, the completed count, and `Resume Review`.
- Resume continues with the next incomplete unit and does not intentionally rerun completed paper-level work.

`Pause Review` stops new work and retains all checkpoints and intermediate files. `Cancel Review…` requires confirmation and deletes the incomplete job's working state without changing Search History or any `Use` selection.

Completed Review versions cannot be cancelled. They can be opened, copied, revealed in Finder, or deleted explicitly.

## Error Handling

Normal classification uncertainty does not interrupt the task. The Review Engine records access status, extraction confidence, eligibility, analysis suitability, and methodological limitations in the deliverables.

The task pauses only when it cannot make meaningful progress:

| Condition | User-visible state | Recovery |
|---|---|---|
| ChatGPT/Codex login expired | `Reconnect ChatGPT` | Reauthorize, then resume the same job |
| Subscription allowance unavailable | `Review paused — Codex allowance unavailable` | Resume after allowance is available |
| No `Use` papers | Start action disabled | Mark at least one paper `Use` |
| All selected papers lack usable URLs | Start blocked | Change the selection or sources |
| All sources are inaccessible | `Review paused — no accessible sources` | Retry or cancel without losing Search History |
| Temporary network or source failure | Retrying with bounded backoff | Continue automatically or pause after retry limit |
| Workbook or manuscript generation failure | `Review paused — output generation failed` | Retry only the failed output stage |
| Deliverable verification failure | `Review paused — verification failed` | Regenerate or repair the affected deliverable |

An error never deletes the immutable manifest, durable checkpoints, completed Review versions, Search History, or `Use` state.

## Storage and Versioning

Managed Review files live under RagBio's Application Support data in a job-specific directory:

```text
RagBio/Reviews/<job-id>/
    manifest.json
    checkpoint.json
    working/
    outputs/
        <topic>_sr_ma_data_extraction_workbook.xlsx
        <topic>_systematic_review_manuscript.docx
```

Search History stores Review job metadata and stable references, not duplicated workbook or manuscript bytes.

Each new generation creates a new immutable version. It never overwrites a completed version, even when the query text is unchanged. The newest completed version is primary; earlier versions remain under `Previous Reviews`.

Deleting a Search History record that owns Review versions requires an explicit warning that its managed Review jobs and files will also be deleted. Saving copies elsewhere does not transfer lifecycle ownership back to RagBio.

## Built-in Workflow Requirements

The built-in Review Engine preserves the current `sr-ma-from-paper-urls` principles:

- Never fabricate undocumented systematic-review process items.
- Keep access/source status separate from publication/study type.
- Build and internally validate the extraction workbook before writing manuscript prose.
- Separate study-level inclusion from endpoint-specific pooling eligibility.
- Keep clinically distinct endpoint families separate.
- Run quantitative synthesis only when the supplied data and study set support it.
- Select domain-appropriate risk-of-bias tools.
- Record GRADE certainty and systematic-review readiness honestly.
- Produce an English manuscript unless a later product requirement adds a language choice.
- Verify workbook structure and formulas.
- Render and visually inspect the manuscript before marking the job complete.

The workflow, prompts, scripts, references, templates, and output schemas must be bundled and versioned as application resources. Users do not install or update a separate Skill.

## Verification Strategy

### Unit Tests

- Current-search `Use` selection produces the exact expected manifest.
- Manifest creation and manual URL export resolve and normalize URLs identically.
- DOI, PMID, OpenAlex ID, and URL deduplication follow the defined precedence.
- Missing URLs produce correct usable and skipped counts.
- A manifest remains unchanged after later `Use` or Search History changes.
- Only one job can transition to `running`.
- Pause and resume select the next incomplete unit.
- Cancellation removes only incomplete job data.
- Completed versions are never overwritten.
- Deleting Search History requires and performs the documented Review cleanup.

### Integration Tests

- A fixture Review streams stages and paper counts into the workspace.
- App relaunch restores a paused job from a durable checkpoint.
- Authentication and allowance failures preserve state and resume correctly.
- Output-stage retry does not repeat completed extraction.
- `Open Excel`, `Open Word`, `Save Copies…`, and `Show in Finder` target the correct version.
- A second search cannot start a job while another job is running.

### Deliverable Tests

- The workbook contains the required sheets and typed analysis data.
- Formula-error scans and representative-sheet rendering pass.
- The manuscript contains the required sections and readiness checklist.
- DOCX page rendering has no clipped text, overlapping content, broken tables, or unacceptable pagination.
- Source audit counts reconcile with the immutable manifest and final study accounting.

### Technical Spike Exit Criteria

Before implementing the full Review workflow, a minimal local spike must prove:

1. RagBio can start Codex work without opening the Codex application.
2. The bundled SDK/runtime can use the supported ChatGPT browser login and cached session.
3. The run uses the eligible user's Codex access rather than a RagBio-owned API key.
4. RagBio receives structured progress and blocking-error events.
5. A paused local job can resume after the helper process and RagBio restart.
6. A fixture job can create and open one `.xlsx` and one `.docx` artifact.
7. The chosen runtime can be packaged, signed, notarized, and distributed with RagBio under applicable terms.

Failure of the authentication, subscription, or distribution criteria does not invalidate the Review Engine design. It requires replacing the Codex adapter before public release.
