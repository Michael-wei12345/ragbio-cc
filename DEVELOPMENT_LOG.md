# RagBio Development Log

## 2026-07-09 - Per-paper "Article Summary" (systematic-review extraction note)

Status: Success (builds); AI output quality pending user test.

### Goal

Replace the displayed per-paper "Literature Review Summary" with the user's systematic-review-oriented extraction note: 7 sections (one-line takeaway; study type & role in review; PICO/PECO; methods that matter; main biological findings; limitations & confounders; how to use in review), strictly grounded in full text, "Not reported" when absent, ~250–450 words, English.

### Changes

- `AIQueryPlanner.articleExtractionNote(work:document:configuration:)`: builds the 7-section note prompt from the full-text excerpts (`fullTextSummaryContext`), returns it through the existing JSON pipeline as `{"note":"..."}`.
- `SearchStore`: added `articleSummaries` / `articleSummaryInProgress` / `articleSummaryErrors` and `ensureArticleSummary(for:)` — lazy, best-effort, generated the first time the user opens a full-text paper.
- `ContentView`: the paper detail now shows an `ArticleSummaryView` (titled "Article Summary") in place of `LiteratureReviewSummaryCard`; triggered via `.task(id: work.id)` and on full-text load.

### Design Notes

- Lazy (per opened paper), so it does NOT fire for all ~20 auto-read papers — keeps cost down.
- The structured `LiteratureReviewSummary` is still generated (eager) and still feeds the field summary; only the *display* changed. `LiteratureReviewSummaryCard` + its source-excerpt path are now unused (dead code for now).
- Rendered as faithful structured text (selectable). Section-aware styling / clickable Locate can come later.

### Verification

- `swift build` + `scripts/build-app.sh` passed. AI output quality pending user test.

## 2026-07-09 - Make the field summary concise; drop the Use-only generate button

Status: Success (builds); reader-friendliness pending user test.

### Goal

User feedback: the field summary was too long, unfocused, and not reader-friendly. Make it short and scannable, and remove the second (Use-marked) generate button.

### Changes

- `AIQueryPlanner.fieldScanDraft` prompt: now asks for a short, high-signal scan with hard caps (field_overview ≤3 sentences leading with the bottom line; key_findings ≤5 one-liners; conflicting_evidence / research_gaps ≤3; must_read ≤6). Lowered `maxTokens` from up to 8000 to 3000.
- `FieldSummaryView`: redesigned to the essentials only — a prominent one-paragraph verdict, 要点 (≤5), 分歧与空白 (conflicting + gaps merged, ≤4), and 必读论文 (≤6, clickable). Dropped the themes / methods / future-directions / limitations sections. Each claim now shows a compact "level · N 篇" tag instead of a long inline list of paper titles (titles live in must-read).
- `ContentView`: removed the 领域 summary（我 Use 的）button; the single button is now 生成领域 summary (top ~30 results). `SearchStore`'s `.marked` scope stays but is now unused.

### Verification

- `swift build` + `scripts/build-app.sh` passed. Reader-friendliness pending user test.

## 2026-07-09 - Unify marking to Use, remove 收藏 + 我的文库 tab, add "export Use URLs to txt"

Status: Success (builds); export pending user test.

### Goal

Complete the core scoping loop's last step (export) and unify "keep a paper" onto one action. Per the redesign: `Use` is the only "keep" mark, long-term保存 is via named Projects, and the standalone library goes away.

### Changes

- Added `SearchStore.exportUseMarkedURLs()`: collects the landing-page URLs of Use-marked works and writes them one-per-line to a `.txt` file via a save panel. Fixed `exportText` to allow a `.txt` content type (it previously forced `.md` for anything non-CSV).
- `ContentView`: added an 导出 Use 的 URL button in the scan-filter bar (disabled until a paper is marked Use); removed the 收藏 (favorite) button from the paper detail header; removed the 在线检索 / 我的文库 workspace switcher and the 我的文库 (`LibraryView`) tab, so the app is now a single search workspace; removed the now-unused `AppWorkspace` enum and workspace state.

### Design Notes

- "Import PDF" for a paper's full text is unaffected (it routes through `SearchStore.importPDF`, not the library).
- Backend still present as dead code (deferred): `LibraryStore` / `LibraryService` / `LibraryView`, favorite logic, and the menu command 导入 PDF 到文库. To be removed in a careful follow-up (persistence-coupled).

### Verification

- `swift build` + `scripts/build-app.sh` passed. Export save-dialog + file contents pending user test.

## 2026-07-09 - Field-level summary (Overview) — two buttons, over top results or Use-marked papers

Status: Success (builds); AI output quality pending user test.

### Goal

Step 4 of the redesign: a field-level summary that helps the user see the state + frontier of a field from a search. Two explicit buttons the user chooses between: ① from the top ~30 current results, ② from the papers the user marked Use.

### Changes

- Reused the (previously hidden) Field Scan generator instead of rebuilding: added `FieldScanService.generate(rows:query:normalizedQuery:configuration:)` taking an explicit pre-selected row set (the existing `generate(table:)` now delegates to it), and `EvidenceTableService.rows(for:input:)` that builds rows for an explicit works list without the Use/Maybe re-selection.
- `SearchStore`: added `fieldSummary` / `isGeneratingFieldSummary` / `fieldSummaryError` state, `FieldSummaryScope` (`.topResults` / `.marked`), `generateFieldSummary(scope:)`, `hasMarkedUseWorks`, and `workTitleLookup`. `.topResults` = top 30 ranked works; `.marked` = works with a Use decision. Cleared on new search.
- `ContentView`: two buttons under the search box (领域 summary（全部） / 领域 summary（我 Use 的）), the second disabled until a paper is marked Use; the result is shown in a full-width sheet via a new `FieldSummaryView` (overview + themes + findings + conflicts + gaps + future directions + must-read + limitations, each claim listing its supporting paper titles and evidence level).

### Design Notes

- Output reuses the `FieldScanReport` model + work_id validation, so every claim still cites real input work_ids and abstract-only vs full-text is labeled. The field summary is the retained, repurposed successor to the removed Field Scan UI.
- v1 reuses the existing `fieldScanDraft` prompt as-is.

### Verification

- `swift build` + `scripts/build-app.sh` passed. AI output quality pending user test (needs their configured provider).

### Follow-up: clickable must-read papers

- Added `SearchStore.workURLLookup` (workID → `Work.landingPageURL`) and made each must-read paper title in `FieldSummaryView` a button that opens the paper's landing page via `@Environment(\.openURL)`. Builds pass.

## 2026-07-09 - Remove Evidence Table / Field Scan / report / scan-workspace from the UI

Status: Success

### Goal

Simplify the detail and results UI toward the redesigned scoping loop by removing the four pieces the redesign cut: the Evidence Table button, Field Scan, the 证据报告 tab, and the 扫描工作台 tab. Keep 论文信息 and 全文定位, and keep the Use / Maybe / Exclude scan marking (that system is being retained).

### Changes

- `ContentView`: removed the "Evidence Table" button from the scan-filter bar; removed the 证据报告 and 扫描工作台 tabs from the detail `Picker` (detail now shows only 论文信息 and 全文定位); deleted the now-unused view structs `EvidenceReportView`, `EvidenceCard`, `ScanWorkspaceView`, `EvidenceTableView`, and `FieldScanReportView` (~400 lines).

### Design Notes

- UI-only removal in this pass. The backend (`SearchStore` generate/export methods, `currentEvidenceTable` / `currentFieldScanReport` state, `EvidenceTableService`, `FieldScanService`, and their session/project persistence fields) is intentionally left as now-dead code, to avoid touching the session/project persistence schema in the same step. A follow-up will remove the backend + persistence fields carefully so existing saved projects still decode.

### Verification

- `swift build` + `scripts/build-app.sh` passed; relaunched for the user to confirm the tabs are gone and 论文信息 / 全文定位 + marks still work.

## 2026-07-09 - Fix macOS title-bar overlap in the search workspace

Status: Success

### Goal

The window's top bar (workspace switcher + settings) was overlapping the main content on macOS: the search workspace's `NavigationSplitView` hoisted itself into the window title-bar region and drew over the custom header, so content slid under the traffic lights and toolbar buttons and some information was unreachable.

### Changes

- Replaced the search workspace's `NavigationSplitView { sidebar } detail: { detail }` with a plain `HSplitView { sidebar; detail }` in `ContentView`, so the split view no longer competes for the window title bar. Sidebar keeps a 310–460pt width via `.frame`; detail fills the rest.

### Design Notes

- Trade-off: loses the (unused) NavigationSplitView sidebar-collapse toggle. The two-pane resizable layout is preserved.

### Verification

- `swift build` + `scripts/build-app.sh` passed; user confirmed the top bar and content no longer overlap.

## 2026-07-09 - Add PubMed as a second search source

Status: Success

### Goal

Improve search recall (the user's #1 priority: "搜得全") by searching PubMed alongside OpenAlex, so the user needn't leave the app to run a separate PubMed search. First concrete step of the redesign toward a systematic-review scoping tool.

### Changes

- Added `Sources/RagBio/PubMedClient.swift`: NCBI E-utilities client (ESearch to EFetch), a SAX `XMLParser` delegate for efetch XML, and mapping of PubMed records into the app's `Work` model. PubMed automatic term mapping expands plain keywords into MeSH-aware queries, so natural-language search text works without hand-written boolean.
- Extended `Work` in `Models.swift` with `abstractPlain: String?` (PubMed returns plain-text abstracts, not OpenAlex-style inverted indexes); `abstractText` now prefers it. Decodes as absent for OpenAlex JSON.
- Wired PubMed into `SearchStore`:
  - AI search (`fetchAICandidates`): fetch PubMed candidates alongside OpenAlex, merge + dedup, reserving pool slots for PubMed-only finds so they are not truncated when OpenAlex already fills the candidate limit.
  - Keyword search (`loadPage`): merge PubMed into page 1.
  - Added best-effort `fetchPubMedCandidates` (failures return [] and never block OpenAlex) and static `mergeDedup` / `dedupKeys` (by normalized DOI, PMID, then title).
- Reused `SettingsKeys.contactEmail` as the NCBI courtesy email; PubMed needs no API key.

### Design Notes

- Best-effort: any PubMed error or timeout (12s) yields an empty list, so OpenAlex results are never blocked.
- Dedup prefers the OpenAlex record on collision (richer OA/citation metadata); PubMed-only papers are appended.
- Deferred to later steps (intentionally out of scope here): LLM-built precise boolean/MeSH queries, showing/editing the query, citation chasing, more sources, and cross-source relevance re-ranking for keyword mode.

### Verification

- `swift build` passed; `scripts/build-app.sh` rebuilt `dist/RagBio.app`.
- Verified the new ESearch to EFetch to XML-parse to mapping pipeline against the live PubMed API with the user's real query ("children early gastrointestinal symptoms autism prediction"): 6/6 records parsed with correct titles, abstracts (structured labels included), authors, journal, year, DOI, and PMCID. Top hit was a relevant Lancet Neurology 2023 review on predicting autism in infants.

### Follow-up fix (same day): PubMed returned 0 results for AI searches

- Root cause found while testing in-app: the AI plan's OpenAlex keyword string (many space-separated terms) was passed straight to PubMed, which ANDs terms — a 13-term query matched 0 records (confirmed via live ESearch: long query -> 0, boolean query -> ~960). Separately, the "PubMed 补充" notice was being overwritten a few seconds later by the coarse-ranking notice.
- Fix: added `pubmed_query` to `AISearchPlan` and the planner prompt so the model emits a proper PubMed boolean query (OR-grouped synonyms, two or three AND-joined concept groups); `fetchAICandidates` now sends that to PubMed instead of the OpenAlex keyword string. Surfaced the merge result via a dedicated `pubMedNotice` that later notices no longer overwrite (shown in the results header; also set for keyword page 1).
- Verified: `swift build` and `scripts/build-app.sh` passed; live ESearch confirmed the boolean form returns results where the flat keyword string returned 0.

## 2026-07-09 - GPT handoff context document

Status: Success

### Goal

Create a single Markdown document that can be handed to GPT or an external engineering/product collaborator so they can understand RagBio without reading the full chat history.

### Changes

- Added `RAGBIO_GPT_HANDOFF.md`.
- Summarized the current product goal, information sources, trusted evidence boundary, online search flow, AI search pipeline, full-text retrieval chain, PDF/OCR parsing, local retrieval, Literature Review Summary, source passage tracing, translation, library, Research Scan, Evidence Table, Field Scan Report, named projects, caching, credentials, UI tabs, failure strategy, and known limitations.
- Included explicit guidance for future GPT/code agents about modularity, logging, validation, and not inventing unsupported paper facts.

### Design Notes

- This is documentation only; it does not change runtime behavior.
- The handoff document is separate from `RAGBIO_APP_LOGIC.md` because it is written for direct GPT consumption rather than only for internal engineering reference.
- The document preserves architecture boundaries: UI, state stores, service layer, parsing, retrieval, persistence, and models are described separately.

### Verification

- Documentation was added with no runtime code changes.
- `git diff --check` should be run after this edit to verify formatting.

## 2026-07-09 - Task 3: Named Research Projects

Status: Success

### Goal

Implement Task 3 from `/Users/menjiwei/Downloads/RagBio_Next_3_Codex_Tasks_v3 (1).md`: keep the existing latest-search autosave, and add multiple named research projects that preserve search state, scan decisions, Evidence Tables, and Field Scan Reports.

### Changes

- Added `Sources/RagBio/OnlineSearchProjectStore.swift`.
- Added project models:
  - `OnlineSearchProjectIndex`
  - `OnlineSearchProjectSummary`
  - `OnlineSearchProject`
- Reused `OnlineSearchSessionSnapshot` as the project `session` payload so project persistence does not duplicate search/session fields.
- Added project storage under:
  - `~/Library/Application Support/RagBio/SearchSession/Projects/index.json`
  - `~/Library/Application Support/RagBio/SearchSession/Projects/<project-id>.json`
- Added `SearchStore` project state:
  - `projectSummaries`
  - `currentProjectID`
  - `projectErrorMessage`
- Added project actions:
  - pin current search as project
  - open project
  - rename project
  - duplicate project
  - delete project
- Updated autosave behavior:
  - no project open: save only `online-search.json`
  - project open: save both `online-search.json` and the current project file
- Opening a project now cancels stale work, increments generation counters, clears transient state, and restores the saved session without restarting expensive AI tasks.
- Added a compact project menu to the online search header.
- Updated `README.md`, `RAGBIO_APP_LOGIC.md`, and `AI_SEARCH_LOGIC.md`.

### Design Notes

- Existing autosave remains backward compatible.
- Existing autosave is not forced into a project; users explicitly pin it.
- Project JSON stores search state, AI ranking metadata, scan decisions, Evidence Tables, Field Scan Reports, and notes.
- Project JSON does not store API keys, publisher credentials, translation cache, active task state, or raw full-text body.
- Full text continues to be restored lazily from the existing full-text cache.

### Verification

- `swift build` passed after the project store and UI were added.
- `scripts/build-app.sh` passed and rebuilt `/Users/menjiwei/Documents/rag-bio/dist/RagBio.app`.
- `git diff --check` passed.

## 2026-07-09 - Correct Task 1/2 alignment from RagBio_Next_3_Codex_Tasks_v3

Status: Success

### Goal

Verify whether the previously completed "Task 1" and "Task 2" matched `/Users/menjiwei/Downloads/RagBio_Next_3_Codex_Tasks_v3 (1).md`, then implement the missing behavior from that file.

### Finding

The earlier completed items were useful, but they were not the Task 1/2 defined in the new MD:

- Earlier Task 1: field-level source citations for Literature Review Summary.
- Earlier Task 2: OpenAlex query synonym expansion.
- Actual MD Task 1: Scan Decisions plus deterministic Evidence Table.
- Actual MD Task 2: Field Scan Report generated from Evidence Table rows.

### Changes

- Added `Sources/RagBio/ScanModels.swift` for scan decisions, Evidence Table rows, access status, source refs, Field Scan reports, support levels, themes, claims, and must-read papers.
- Added `Sources/RagBio/EvidenceTableService.swift` to generate deterministic Evidence Tables without calling an LLM.
- Added `Sources/RagBio/FieldScanService.swift` to generate Field Scan Reports only from Evidence Table rows, validate `supporting_work_ids`, drop unsupported claims, compute support levels, and cap section sizes.
- Extended `AIQueryPlanner` with a Field Scan JSON prompt that only accepts Evidence Table rows as source material.
- Extended `SearchStore` with `scanDecisions`, `currentEvidenceTable`, `decisionFilter`, `currentFieldScanReport`, export methods, and generation methods.
- Persisted scan decisions, Evidence Table, decision filter, and Field Scan Report in `OnlineSearchSessionStore`.
- Added UI controls for `Use / Maybe / Exclude`, filter chips, Evidence Table generation/export, and Field Scan generation/export.
- Updated `README.md`, `RAGBIO_APP_LOGIC.md`, and `AI_SEARCH_LOGIC.md` so the engineering docs now describe the real Task 1/2 flow.

### Design Notes

- Scan decisions are per current research scan and intentionally separate from global favorites.
- Evidence Table is deterministic and local; it uses current metadata, abstract evidence, AI ranking annotations, existing full-text summaries, and source refs.
- If any `Use` or `Maybe` decisions exist, Evidence Table includes only those rows; otherwise it uses the current ranking and shows a warning.
- `Exclude` rows never enter the Evidence Table.
- Field Scan Report is allowed to use an LLM, but only over Evidence Table rows. Any claim without valid input `work_id` support is removed after decoding.
- The Field Scan decoder tolerates missing optional sections and common category formatting differences such as snake_case.

### Verification

- `swift build` passed.
- `scripts/build-app.sh` passed and rebuilt `/Users/menjiwei/Documents/rag-bio/dist/RagBio.app`.
- `git diff --check` passed.

## 2026-07-09 - Task 1: Literature Review Summary field-level sources

Status: Success

### Goal

Implement the first optimization item from `RAGBIO_APP_LOGIC.md`: bind each Literature Review Summary field to its own supporting full-text paragraph, so `Topic`, `Methods`, `Results`, `Key Metrics`, and `Outlook` are easier to audit.

### Changes

- Added `Sources/RagBio/LiteratureReviewCitationBuilder.swift`.
- Moved summary-field-to-paragraph matching into a standalone builder instead of embedding more logic in `SearchStore`.
- Updated `SearchStore.literatureReviewSourceExcerpts(...)` to build citations from the current `LiteratureReviewSummary` and `FullTextDocument`.
- Updated `LiteratureReviewSummaryCard` so each field can show `Source: <locator>` plus a `Locate` button.
- Kept the existing `Source passages used` disclosure, now populated by field-level source passages.
- Updated `RAGBIO_APP_LOGIC.md` and `AI_SEARCH_LOGIC.md` so engineering docs match the actual behavior.

### Design Notes

- The citation builder is local and deterministic. It does not call a model or network service.
- Matching uses section names, lexical overlap with the summary field, and number overlap for `Key Metrics`.
- This keeps UI, state management, and citation matching separated:
  - `ContentView` renders citations.
  - `SearchStore` provides the current full-text document and summary.
  - `LiteratureReviewCitationBuilder` owns matching logic.

### Verification

- `swift build` passed.
- `scripts/build-app.sh` passed and rebuilt `dist/RagBio.app`.

### Follow-Up

- Field-level citations currently select one best paragraph per field. A future improvement could allow multiple source paragraphs per field when a field combines evidence from several sections.

## 2026-07-09 - Task 2: OpenAlex query synonym map expansion

Status: Success

### Goal

Implement the second optimization item from `RAGBIO_APP_LOGIC.md`: expand the OpenAlex query synonym map so AI search and keyword search are less brittle when users use abbreviations, drug names, database names, or clinical shorthand.

### Changes

- Reworked `Sources/RagBio/OpenAlexQueryNormalizer.swift` from scattered hardcoded conditionals into a `SynonymRule` table.
- Added conservative expansions for MeSH-like disease concepts, drug and treatment aliases, healthcare database names, coding systems, and population terms.
- Covered examples such as `NDC`, `RxNorm`, `FAERS`, `OMOP`, `ICD`, `CPT`, `MedDRA`, `IBD`, `NSCLC`, `NSAID`, `PPI`, `GLP-1`, `children`, and `female`.
- Kept original user terms and appended expansions instead of replacing user intent.
- Avoided highly ambiguous abbreviations such as standalone `AD` and `PD`, because they can mean different things across biomedical contexts.
- Updated `README.md`, `RAGBIO_APP_LOGIC.md`, and `AI_SEARCH_LOGIC.md` to document the new normalizer behavior.

### Design Notes

- The normalizer is deterministic and local. It does not call a model or network service.
- It still removes Boolean syntax and field syntax before sending search text to OpenAlex, because OpenAlex `search` is ordinary text search rather than a full Boolean query language.
- The query keeps a length cap of 40 terms so synonym expansion does not turn a user prompt into an oversized noisy search string.
- The rule table is intentionally easy to extend: new abbreviations should be added as data, not as new branching logic.

### Verification

- `swift build` passed.
- `scripts/build-app.sh` passed and rebuilt `dist/RagBio.app`.
- `git diff --check` passed.
