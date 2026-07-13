# RagBio AI Search History Design

Date: 2026-07-13
Status: Approved in conversation; pending written-spec review

## 1. Goal

Replace RagBio's manually managed Project model with an automatic, local AI search history. A user should be able to focus the search field, choose an earlier query, and restore the exact saved research state without rerunning AI or network searches.

The design must preserve the user's accumulated `Use` selections when an identical query is refreshed. It must also support selecting multiple search histories and exporting their Use URLs into one structured TXT file.

## 2. Scope

This change includes:

- Remove Keyword Search and leave AI Search as the only search mode.
- Remove the existing Project bar, named Projects, pin, rename, and duplicate actions.
- Replace Project persistence with automatic search-history persistence.
- Preserve the selected year and other active filters as part of the saved search snapshot.
- Restore saved results, filters, AI ranking state, and Use selections from history.
- Accumulate Use selections across successful refreshes of the same user input.
- Add multi-history Use URL export through an English modal sheet and the native macOS Save panel.
- Delete legacy Project and Autosaved Search data once when the new history system is first enabled.

This change does not include:

- SQLite in the initial implementation.
- Cloud sync or cross-device history.
- Named projects, folders, tags, or manual pinning.
- Saving raw PDF bodies or full-text paragraph copies inside history records.
- A TXT preview page.
- Automatic history expiration.
- Migration of old Projects into the new history format.

## 3. Search Field and History Interaction

### 3.1 Search field

- The search field has no magnifying-glass area on the left.
- A clear, visible search button is attached to the right side.
- Pressing Return and clicking the search button perform the same new-search action.
- There is no clear `×` control in this design.

### 3.2 Opening and filtering history

- Focusing an empty search field opens search history directly below the field.
- The history popover has a fixed visible height of approximately seven rows and scrolls internally.
- Rows are ordered by the last successful search time, newest first.
- Each row displays only the user's original input. It does not display time, Use count, paper count, grouping, or generated AI search terms.
- Typing filters the complete local history by the displayed user input.
- The list is not grouped by day or any other category.
- Clicking a history row restores its saved snapshot. It does not call AI, access the network, or resume old background tasks.

### 3.3 Search identity

A history record is identified only by normalized user input. Normalization:

- trims leading and trailing whitespace;
- collapses consecutive whitespace;
- compares case-insensitively;
- does not remove punctuation;
- does not perform semantic equivalence or synonym matching.

Year, open-access filters, sort, generated AI plan, provider, and model are properties of the latest snapshot, not part of history identity. Therefore, identical user input always maps to one history row.

### 3.4 New searches and refreshes

- A different normalized input begins a new history record after first usable results appear.
- An identical normalized input explicitly refreshes the existing record when the user presses Return or clicks the search button.
- Clicking the existing history row restores the snapshot instead of refreshing it.
- During an identical-query refresh, the previous All results remain visible with `Refreshing…`.
- During a different-query search, unrelated old results are hidden and the new loading state is shown.
- A failed, cancelled, timed-out, or zero-result search does not replace an existing snapshot.
- The old snapshot remains on disk until new first usable results have been written successfully.
- A successful refresh replaces All, updates the saved filters and AI state, and moves the history row to the top.

### 3.5 Staged AI completion

- First usable results create or replace the All snapshot.
- Later AI ranking, full-text enrichment, and summary completions update the same history record.
- Each update saves only a completed state; an in-progress task is never persisted as resumable work.
- If RagBio closes during later processing, the next launch restores the latest fully written stage and does not automatically rerun AI.
- The last opened history record is restored automatically when RagBio launches. If no history exists, RagBio opens to an empty search state.

## 4. Persistent Use Ledger

All and Use have different lifetimes:

- All contains the latest successful results for the normalized user input.
- Use contains the accumulated papers selected across every successful refresh of that input.

Rules:

- Refreshing All never clears the Use ledger.
- A used paper that reappears in new All results is automatically marked Use.
- A used paper that does not reappear remains visible in the Use filter and remains exportable.
- Only an explicit user action that cancels Use removes a paper from the ledger.
- Background AI updates may update All and AI-related fields but cannot overwrite the Use ledger.

Paper matching uses the first available stable identity:

1. normalized DOI;
2. PMID;
3. OpenAlex Work ID;
4. a conservative fallback based on normalized title, publication year, and author data.

The OpenAlex identifier shown as values such as `W2793031757` is not a DOI. DOI matching is internal and is not required to appear in the main UI.

## 5. History Deletion and Retention

- History does not expire automatically.
- The popover's fixed height and lazy rendering prevent a large history from expanding the UI.
- Filtering searches the lightweight index rather than loading paper records.
- A user deletes one history row through its context menu using `Delete Search History`.
- A record with no Use entries may be deleted directly.
- A record containing Use entries requires an English destructive confirmation explaining that its accumulated Use ledger will also be deleted.
- Deleting the currently open history returns to an empty search state; it does not open a different history automatically.
- Deleting history does not remove FullText cache entries, local Library data, settings, or other histories.
- There is no global one-click clear-history action.

## 6. Local Persistence

### 6.1 File layout

```text
~/Library/Application Support/RagBio/SearchHistory/index.json
~/Library/Application Support/RagBio/SearchHistory/records/<history-id>.json
```

`index.json` is lightweight and contains:

- schema version;
- history ID;
- display input;
- normalized input;
- creation time;
- last successful search time;
- Use count;
- last opened history ID.

Each independent record contains:

- schema version and history ID;
- original and normalized user input;
- creation and update timestamps;
- latest successful All snapshot;
- latest filters and generated AI plan;
- latest AI ordering, scores, reasons, and evidence levels;
- selected paper and page state;
- available article summaries;
- persistent Use ledger with the metadata needed to display and export each paper.

A record does not contain:

- API keys or provider credentials;
- active Tasks, loading flags, or transient errors;
- raw PDF bytes;
- duplicated full-text paragraphs;
- publisher session data.

Full text remains in the existing FullText cache and is located by paper identity when needed.

### 6.2 Store boundary

`SearchHistoryStore` owns index and record persistence. UI and search orchestration call store operations rather than reading JSON paths directly. The initial implementation remains a concrete JSON-backed store; no speculative protocol or database layer is required.

This boundary permits a future SQLite migration without rewriting the UI. A later migration can import JSON records in a transaction, verify record and Use counts, retain a JSON backup, and switch only after verification succeeds.

### 6.3 Write safety and loading

- Record writes are serialized so AI updates and Use updates cannot overwrite one another.
- All files use atomic replacement.
- `index.json` is updated only after its corresponding record write succeeds.
- Launch loads only `index.json`.
- A complete record is loaded only when the user opens it.
- The history filter searches only index summaries.
- If `index.json` is damaged, RagBio rebuilds it by scanning valid record files.
- A damaged record is omitted with an error and does not block other records.

## 7. Legacy Data Reset

The first launch of the new history schema performs a one-time reset of:

- `SearchSession/Projects/index.json`;
- legacy Project record JSON files;
- `SearchSession/online-search.json` Autosaved Search.

It does not delete:

- FullText cache;
- local Library PDFs or catalog;
- AI provider settings or API keys;
- application preferences unrelated to legacy search persistence.

After the reset, Search History is empty until the first AI search returns usable results.

## 8. Export Use URLs

### 8.1 Modal flow

- The existing `Export Use URLs` action opens an English modal sheet attached to the current RagBio window.
- It does not open a new page or a new app window.
- The sheet shows only histories with at least one Use entry.
- Rows are ordered newest first and show the original user input plus Use count.
- The current history is selected by default when it has Use entries.
- `Select All`, `Clear`, and a selected-count indicator are available.
- Export is disabled when no history is selected.
- The primary button label includes the deduplicated URL count, for example `Export 10 URLs…`.
- Clicking Export opens the native macOS Save panel.
- There is no in-app TXT preview.

### 8.2 URL selection

Each used paper contributes at most one URL per chunk, chosen in this order:

1. canonical `https://doi.org/...` URL;
2. PubMed page;
3. publisher or canonical landing page;
4. OpenAlex work page.

Direct PDF URLs are not exported because they are less stable and may depend on temporary access.

Rules:

- Duplicate URLs are removed within one chunk.
- The same URL may appear in different chunks because each chunk represents a different research question.
- Used papers without a usable URL remain in Use but are skipped during export.
- Completion reports both exported and skipped counts, for example: `Exported 12 URLs. Skipped 2 papers without a usable URL.`

### 8.3 TXT format

Selected histories are written from oldest to newest, even though the selection list is displayed newest first. Each chunk uses English labels and one URL per line:

```text
------
Query: pediatric intestinal inflammation
Search Time: 2026-07-10 14:20
https://doi.org/10.1000/example-a
https://pubmed.ncbi.nlm.nih.gov/12345678/
------
Query: gut microbiota autism
Search Time: 2026-07-12 09:15
https://doi.org/10.1000/example-b
------
```

The final selected chunk also ends with `------`.

## 9. Error and Concurrency Behavior

- Each search receives a generation identifier.
- Only the latest active generation may update UI or persistence.
- Starting another search or opening history cancels previous tasks.
- Late results from cancelled work are ignored.
- Failed, cancelled, timed-out, and zero-result searches do not overwrite saved history.
- A disk write failure keeps the last valid file and shows `Search completed, but history could not be saved.`
- A failed Use write restores the previous visible Use state and reports the failure.
- Cancelling the native Save panel is not an error.
- A TXT write failure keeps the export sheet open and reports the underlying error.
- Export and deletion never mutate unrelated history records.

## 10. Verification

### 10.1 Storage and orchestration tests

- normalization merges case and whitespace variants but not punctuation variants;
- identical input maps to one history record;
- filter changes replace the latest snapshot rather than create duplicate rows;
- successful refresh replaces All and retains Use;
- an old used paper absent from new All remains in Use;
- zero-result and failed refreshes preserve the previous snapshot;
- cancelled or stale generations cannot update current history;
- each completed AI stage updates the same record;
- restart restores the last opened completed stage without invoking AI;
- atomic write failures leave the previous record valid;
- a damaged record does not block other records;
- a damaged index rebuilds from valid records;
- legacy reset deletes only the approved old Project and Autosaved Search files.

### 10.2 Export tests

- only selected histories with Use are exported;
- URL selection follows DOI, PubMed, publisher, and OpenAlex priority;
- URLs deduplicate within chunks but may repeat across chunks;
- missing URLs are skipped and counted;
- chunks are ordered oldest to newest;
- English labels and separators match the specified text format;
- cancelling the Save panel does not change history or Use.

### 10.3 UI and end-to-end tests

- the AI-only search field has no left magnifying-glass area and has a visible search button on the right;
- Return and the search button trigger identical new-search behavior;
- focus opens a fixed-height scrolling history list;
- typing filters all indexed history;
- history rows display only original user input;
- clicking history performs no network or AI request;
- identical-query refresh shows prior All with `Refreshing…`;
- different-query search does not display unrelated old papers;
- Use persists through refresh and restart;
- context deletion confirms when Use exists;
- the export modal is fully English and uses the native Save panel;
- a multi-history export matches chunk ordering, URL priority, deduplication, and skipped counts;
- a large generated index does not noticeably block app launch or history filtering.

## 11. Acceptance Criteria

The feature is complete when:

- a user can restore any saved AI search without consuming AI or network resources;
- identical user input never creates duplicate history rows;
- refreshing identical input never silently loses Use;
- any failed search or failed write preserves the last valid snapshot;
- history remains usable as its record count grows;
- selected Use URLs export to the approved English TXT format;
- the old Project and Keyword Search experiences are no longer present;
- legacy Project and Autosaved Search data are cleared once without affecting FullText, Library, credentials, or settings.
