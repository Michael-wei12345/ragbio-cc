# RagBio AI Search History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace RagBio Projects and Keyword Search with a local, restorable AI Search History whose Use selections survive same-query refreshes and can be exported across multiple histories.

**Architecture:** Add a concrete actor-backed `SearchHistoryStore` that owns a lightweight JSON index and one atomic JSON record per query. Keep query normalization, paper matching, Use merging, and TXT rendering as small pure types; let `SearchStore` orchestrate AI stages and persist only completed snapshots. SwiftUI reads lightweight summaries for the history dropdown and lazily loads full records only when opened or exported.

**Tech Stack:** Swift 5 language mode, SwiftPM, macOS 13+, SwiftUI, AppKit, Foundation, XCTest; no third-party packages and no SQLite in this version.

## Global Constraints

- AI Search is the only search mode; remove Keyword Search and the Project UI.
- A history identity is case-insensitive user input with edge whitespace trimmed and internal whitespace collapsed; punctuation is preserved.
- Identical input has one history row; successful refresh replaces All, moves the row first, and never clears Use.
- A failed, cancelled, timed-out, zero-result, stale-generation, or failed-write refresh cannot replace the last valid record.
- History rows show only original user input, newest first, in an approximately seven-row scrolling dropdown with no left magnifying-glass area and no clear control.
- History is local, never expires automatically, and loads only its index at launch.
- Persistence stays JSON index plus independent JSON records behind one concrete store; do not add a protocol, database, or dependency.
- The one-time legacy reset deletes only `SearchSession/Projects` and `SearchSession/online-search.json`.
- The export selection sheet and destructive deletion confirmation are English; the rest of the existing app localization is unchanged.
- Export chooses DOI, then PubMed, then publisher landing page, then OpenAlex; direct PDF URLs are never exported.
- Preserve unrelated existing worktree changes, especially the current edits in `Sources/RagBio/ContentView.swift`.

---

## File Map

- Create `Sources/RagBio/SearchHistoryModels.swift`: query identity, paper identity, Use ledger, history index/record/snapshot models.
- Modify `Sources/RagBio/Models.swift`: make DOI normalization accept canonical URL and `doi:` forms case-insensitively.
- Create `Sources/RagBio/SearchHistoryStore.swift`: actor-isolated JSON persistence, index rebuild, deletion, Use mutation, and one-time legacy reset.
- Create `Sources/RagBio/SearchHistoryExport.swift`: stable URL resolution and deterministic multi-history TXT generation.
- Create `Sources/RagBio/SearchHistoryViews.swift`: search/history field, deletion prompt, and English export selection sheet.
- Modify `Sources/RagBio/SearchStore.swift`: remove Project/session ownership, restore history lazily, preserve Use, persist completed AI stages, cancel stale work, expose export/deletion APIs.
- Modify `Sources/RagBio/ContentView.swift`: remove Project/search-mode controls and old export button behavior; install the new history field and sheet.
- Modify `Sources/RagBio/AIProvider.swift`: remove obsolete `SearchMode` after all consumers are migrated.
- Modify `Sources/RagBio/RagBioApp.swift`: keep command search AI-only and remove any implicit relaunch search behavior from the root view.
- Delete `Sources/RagBio/OnlineSearchSessionStore.swift`: replaced by `SearchHistoryStore`.
- Delete `Sources/RagBio/OnlineSearchProjectStore.swift`: replaced by `SearchHistoryStore`.
- Modify `Package.swift`: add the `RagBioTests` test target.
- Create `Tests/RagBioTests/TestFixtures.swift`: deterministic `Work`, snapshot, record, and temporary-directory factories.
- Create `Tests/RagBioTests/SearchHistoryModelsTests.swift`: normalization, paper matching, and Use-ledger tests.
- Create `Tests/RagBioTests/SearchHistoryStoreTests.swift`: persistence, atomicity, index rebuild, corruption isolation, deletion, and legacy reset tests.
- Create `Tests/RagBioTests/SearchHistoryExportTests.swift`: URL priority, deduplication, order, formatting, and skip-count tests.
- Create `Tests/RagBioTests/SearchStoreHistoryTests.swift`: restore, Use persistence, refresh protection, and cancellation-generation integration tests.

---

### Task 1: Add the Test Target and Pure History Models

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/RagBio/Models.swift`
- Create: `Sources/RagBio/SearchHistoryModels.swift`
- Create: `Tests/RagBioTests/TestFixtures.swift`
- Create: `Tests/RagBioTests/SearchHistoryModelsTests.swift`

**Interfaces:**
- Produces: `SearchQueryIdentity.normalize(_:) -> String`
- Produces: `PaperIdentity.init(work:)`, `PaperIdentity.matches(_:) -> Bool`
- Produces: `UseLedger.mark(_:, at:)`, `UseLedger.remove(_:)`, `UseLedger.contains(_:)`
- Produces: `SearchHistoryIndex`, `SearchHistorySummary`, `SearchHistoryRecord`, and `SearchHistorySnapshot`
- Consumes: existing `Work`, `SearchSort`, `AISearchPlan`, `LiteratureReviewSummary`, `EvidenceTable`, and `FieldScanReport`

- [ ] **Step 1: Add a SwiftPM test target**

Add a comma after the existing executable target and place this target immediately after it in the `targets` array:

```swift
.testTarget(
    name: "RagBioTests",
    dependencies: ["RagBio"],
    path: "Tests/RagBioTests"
)
```

- [ ] **Step 2: Add deterministic test fixtures**

Create `Tests/RagBioTests/TestFixtures.swift`:

```swift
import Foundation
@testable import RagBio

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeWork(
    id: String = "https://openalex.org/W1",
    doi: String? = "https://doi.org/10.1000/example",
    pmid: String? = "https://pubmed.ncbi.nlm.nih.gov/123/",
    title: String = "Example Paper",
    year: Int? = 2024,
    author: String? = "A. Author",
    publisherURL: String? = "https://publisher.example/article"
) -> Work {
    Work(
        id: id,
        doi: doi,
        title: title,
        publicationDate: year.map { "\($0)-01-01" },
        publicationYear: year,
        citedByCount: 0,
        authorships: author.map {
            [Authorship(author: Author(id: nil, displayName: $0))]
        } ?? [],
        abstractInvertedIndex: nil,
        primaryLocation: Location(
            isOpenAccess: true,
            landingPageURL: publisherURL,
            pdfURL: "https://publisher.example/article.pdf",
            source: Source(displayName: "Example Journal"),
            license: nil,
            version: nil
        ),
        bestOpenAccessLocation: nil,
        openAccess: OpenAccess(isOpenAccess: true, status: "gold", openAccessURL: nil),
        contentURLs: nil,
        hasFullText: false,
        ids: WorkIDs(pmid: pmid, pmcid: nil),
        locations: [],
        isRetracted: false,
        type: "article",
        language: "en",
        abstractPlain: "Fixture abstract"
    )
}

func makeSnapshot(query: String, works: [Work]) -> SearchHistorySnapshot {
    SearchHistorySnapshot(
        revision: 0,
        displayQuery: query,
        retrievalQuery: query,
        sort: .relevance,
        fromYearEnabled: false,
        fromYear: 2020,
        openAccessOnly: false,
        allWorks: works,
        rankedWorks: works,
        totalCount: works.count,
        currentPage: 1,
        selectedWorkID: works.first?.id,
        lastAIPlan: nil,
        aiReasons: [:],
        aiScores: [:],
        aiEvidenceLevels: [:],
        aiSearchNotice: nil,
        pubMedNotice: nil,
        searchTimingSummary: nil,
        fullTextReviewSummaries: [:],
        articleSummaries: [:],
        currentEvidenceTable: nil,
        currentFieldScanReport: nil
    )
}

func makeRecord(
    id: UUID = UUID(),
    query: String,
    works: [Work],
    date: Date,
    useLedger: UseLedger = UseLedger()
) -> SearchHistoryRecord {
    SearchHistoryRecord(
        schemaVersion: SearchHistoryRecord.currentSchemaVersion,
        id: id,
        displayQuery: query,
        normalizedQuery: SearchQueryIdentity.normalize(query),
        createdAt: date,
        lastSuccessfulSearchAt: date,
        snapshot: makeSnapshot(query: query, works: works),
        useLedger: useLedger
    )
}
```

- [ ] **Step 3: Write failing normalization and Use tests**

Create `Tests/RagBioTests/SearchHistoryModelsTests.swift`:

```swift
import XCTest
@testable import RagBio

final class SearchHistoryModelsTests: XCTestCase {
    func testQueryIdentityNormalizesCaseAndWhitespaceButKeepsPunctuation() {
        XCTAssertEqual(
            SearchQueryIdentity.normalize("  Gut   Microbiota  "),
            "gut microbiota"
        )
        XCTAssertNotEqual(
            SearchQueryIdentity.normalize("gut microbiota"),
            SearchQueryIdentity.normalize("gut-microbiota")
        )
    }

    func testPaperIdentityUsesSharedDOIThenPMIDThenOpenAlexThenFallback() {
        let doiA = makeWork(id: "https://openalex.org/W1")
        let doiB = makeWork(id: "https://openalex.org/W2", doi: "HTTPS://DOI.ORG/10.1000/EXAMPLE")
        XCTAssertTrue(PaperIdentity(work: doiA).matches(PaperIdentity(work: doiB)))

        let fallbackA = makeWork(id: "", doi: nil, pmid: nil)
        let fallbackB = makeWork(id: "", doi: nil, pmid: nil)
        XCTAssertTrue(PaperIdentity(work: fallbackA).matches(PaperIdentity(work: fallbackB)))

        let conflictingDOI = makeWork(id: "", doi: "10.1000/different", pmid: nil)
        XCTAssertFalse(PaperIdentity(work: doiA).matches(PaperIdentity(work: conflictingDOI)))
    }

    func testUseLedgerKeepsMissingPaperAndRefreshesMetadataWhenPaperReturns() {
        let old = makeWork(title: "Old title")
        let refreshed = makeWork(title: "Corrected title")
        var ledger = UseLedger()
        ledger.mark(old, at: Date(timeIntervalSince1970: 1))
        ledger.mark(refreshed, at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(ledger.papers.count, 1)
        XCTAssertEqual(ledger.papers[0].work.title, "Corrected title")
        XCTAssertTrue(ledger.contains(refreshed))
        XCTAssertTrue(ledger.contains(old))
    }

    func testOnlyExplicitRemovalClearsUse() {
        let work = makeWork()
        var ledger = UseLedger()
        ledger.mark(work, at: Date())
        ledger.remove(work)
        XCTAssertFalse(ledger.contains(work))
    }
}
```

- [ ] **Step 4: Run the focused tests and verify they fail**

Run:

```bash
swift test --filter SearchHistoryModelsTests
```

Expected: compilation fails because the history model types do not exist.

- [ ] **Step 5: Normalize DOI forms and implement the pure models**

Replace `Work.normalizedDOI` in `Sources/RagBio/Models.swift` with:

```swift
var normalizedDOI: String? {
    guard let doi else { return nil }
    let normalized = doi
        .lowercased()
        .replacingOccurrences(
            of: #"^(https?://(dx\.)?doi\.org/|doi:\s*)"#,
            with: "",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return normalized.isEmpty ? nil : normalized
}
```

Create `Sources/RagBio/SearchHistoryModels.swift` with these public-to-module definitions:

```swift
import Foundation

enum SearchQueryIdentity {
    static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct PaperIdentity: Codable, Hashable {
    let keys: [String]

    init(work: Work) {
        var values: [String] = []
        if let doi = work.normalizedDOI?.lowercased(), !doi.isEmpty {
            values.append("doi:\(doi)")
        }
        if let pmid = work.normalizedPMID?.lowercased(), !pmid.isEmpty {
            values.append("pmid:\(pmid)")
        }
        let openAlex = work.shortID.lowercased()
        if openAlex.hasPrefix("w"), openAlex.dropFirst().allSatisfy(\.isNumber) {
            values.append("openalex:\(openAlex)")
        }
        let title = Self.words(work.title)
        let firstAuthor = Self.words(work.authorships.first?.author.displayName ?? "")
        if !title.isEmpty, let year = work.publicationYear, !firstAuthor.isEmpty {
            values.append("fallback:\(title)|\(year)|\(firstAuthor)")
        }
        var seen = Set<String>()
        keys = values.filter { seen.insert($0).inserted }
    }

    func matches(_ other: PaperIdentity) -> Bool {
        for prefix in ["doi:", "pmid:", "openalex:", "fallback:"] {
            let left = keys.first { $0.hasPrefix(prefix) }
            let right = other.keys.first { $0.hasPrefix(prefix) }
            if let left, let right { return left == right }
        }
        return false
    }

    private static func words(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension PaperIdentity {
    init(keys: [String]) { self.keys = keys }
}

struct UsedPaper: Codable, Equatable, Identifiable {
    var id: String { identity.keys.first ?? work.id }
    var identity: PaperIdentity
    var work: Work
    var selectedAt: Date
}

struct UseLedger: Codable, Equatable {
    private(set) var papers: [UsedPaper] = []

    mutating func mark(_ work: Work, at date: Date = Date()) {
        let identity = PaperIdentity(work: work)
        if let index = papers.firstIndex(where: { $0.identity.matches(identity) }) {
            let mergedKeys = papers[index].identity.keys + identity.keys.filter {
                !papers[index].identity.keys.contains($0)
            }
            papers[index].identity = PaperIdentity(keys: mergedKeys)
            papers[index].work = work
        } else {
            papers.append(UsedPaper(identity: identity, work: work, selectedAt: date))
        }
    }

    mutating func remove(_ work: Work) {
        let identity = PaperIdentity(work: work)
        papers.removeAll { $0.identity.matches(identity) }
    }

    func contains(_ work: Work) -> Bool {
        let identity = PaperIdentity(work: work)
        return papers.contains { $0.identity.matches(identity) }
    }
}

struct SearchHistoryIndex: Codable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var summaries: [SearchHistorySummary]
    var lastOpenedHistoryID: UUID?
    var legacyResetVersion: Int
}

struct SearchHistorySummary: Codable, Equatable, Identifiable {
    var id: UUID
    var displayQuery: String
    var normalizedQuery: String
    var createdAt: Date
    var lastSuccessfulSearchAt: Date
    var paperCount: Int
    var useCount: Int
}

struct SearchHistoryRecord: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var id: UUID
    var displayQuery: String
    var normalizedQuery: String
    var createdAt: Date
    var lastSuccessfulSearchAt: Date
    var snapshot: SearchHistorySnapshot
    var useLedger: UseLedger
}

struct SearchHistorySnapshot: Codable, Equatable {
    var revision: Int
    var displayQuery: String
    var retrievalQuery: String
    var sort: SearchSort
    var fromYearEnabled: Bool
    var fromYear: Int
    var openAccessOnly: Bool
    var allWorks: [Work]
    var rankedWorks: [Work]
    var totalCount: Int
    var currentPage: Int
    var selectedWorkID: Work.ID?
    var lastAIPlan: AISearchPlan?
    var aiReasons: [String: String]
    var aiScores: [String: Int]
    var aiEvidenceLevels: [String: String]
    var aiSearchNotice: String?
    var pubMedNotice: String?
    var searchTimingSummary: String?
    var fullTextReviewSummaries: [String: LiteratureReviewSummary]
    var articleSummaries: [String: String]
    var currentEvidenceTable: EvidenceTable?
    var currentFieldScanReport: FieldScanReport?
}
```

- [ ] **Step 6: Run the model tests**

Run:

```bash
swift test --filter SearchHistoryModelsTests
```

Expected: 4 tests pass.

- [ ] **Step 7: Commit the model foundation**

```bash
git add Package.swift Sources/RagBio/Models.swift Sources/RagBio/SearchHistoryModels.swift Tests/RagBioTests/TestFixtures.swift Tests/RagBioTests/SearchHistoryModelsTests.swift
git commit -m "add AI search history models"
```

---

### Task 2: Add Atomic JSON Persistence and One-Time Legacy Reset

**Files:**
- Create: `Sources/RagBio/SearchHistoryStore.swift`
- Create: `Tests/RagBioTests/SearchHistoryStoreTests.swift`

**Interfaces:**
- Consumes: Task 1 history models.
- Produces: actor `SearchHistoryStore`
- Produces: `bootstrap()`, `loadIndex()`, `loadRecord(id:)`, `record(normalizedQuery:)`, `save(_:)`, `updateSnapshot(historyID:snapshot:)`, `setUse(historyID:work:isUsed:)`, `delete(id:)`, and `setLastOpened(_:)`

- [ ] **Step 1: Write persistence and reset tests**

Create `Tests/RagBioTests/SearchHistoryStoreTests.swift`:

```swift
import Foundation
import XCTest
@testable import RagBio

final class SearchHistoryStoreTests: XCTestCase {
    func testSaveWritesRecordBeforeSortedIndexAndLoadsItBack() async throws {
        let root = try makeTemporaryDirectory()
        let store = SearchHistoryStore(root: root.appendingPathComponent("SearchHistory"), legacyRoot: root.appendingPathComponent("SearchSession"))
        try await store.bootstrap()
        let older = makeRecord(query: "older", works: [makeWork()], date: Date(timeIntervalSince1970: 1))
        let newer = makeRecord(query: "newer", works: [makeWork(id: "https://openalex.org/W2")], date: Date(timeIntervalSince1970: 2))

        _ = try await store.save(older)
        let index = try await store.save(newer)

        XCTAssertEqual(index.summaries.map(\.displayQuery), ["newer", "older"])
        let restored = try await store.loadRecord(id: older.id)
        XCTAssertEqual(restored, older)
    }

    func testDamagedIndexRebuildsFromValidRecordsAndSkipsDamagedRecord() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let store = SearchHistoryStore(root: root, legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession"))
        try await store.bootstrap()
        let valid = makeRecord(query: "valid", works: [makeWork()], date: Date())
        _ = try await store.save(valid)
        try Data("broken".utf8).write(to: root.appendingPathComponent("records/broken.json"))
        try Data("broken".utf8).write(to: root.appendingPathComponent("index.json"))

        let rebuilt = try await store.loadIndex()

        XCTAssertEqual(rebuilt.summaries.map(\.id), [valid.id])
    }

    func testUseMutationIsSerializedAndPersistsMissingPaper() async throws {
        let root = try makeTemporaryDirectory()
        let store = SearchHistoryStore(root: root.appendingPathComponent("SearchHistory"), legacyRoot: root.appendingPathComponent("SearchSession"))
        try await store.bootstrap()
        let record = makeRecord(query: "gut", works: [makeWork()], date: Date())
        _ = try await store.save(record)

        let updated = try await store.setUse(historyID: record.id, work: makeWork(), isUsed: true)

        XCTAssertEqual(updated.useLedger.papers.count, 1)
        let index = try await store.loadIndex()
        XCTAssertEqual(index.summaries.first?.useCount, 1)
    }

    func testSnapshotUpdatePreservesUseAndRejectsOlderRevision() async throws {
        let root = try makeTemporaryDirectory()
        let store = SearchHistoryStore(root: root.appendingPathComponent("SearchHistory"), legacyRoot: root.appendingPathComponent("SearchSession"))
        try await store.bootstrap()
        let work = makeWork()
        let record = makeRecord(query: "gut", works: [work], date: Date())
        _ = try await store.save(record)
        _ = try await store.setUse(historyID: record.id, work: work, isUsed: true)
        var newer = record.snapshot
        newer.revision = 2
        newer.searchTimingSummary = "newer"
        _ = try await store.updateSnapshot(historyID: record.id, snapshot: newer)
        var stale = record.snapshot
        stale.revision = 1
        stale.searchTimingSummary = "stale"

        let final = try await store.updateSnapshot(historyID: record.id, snapshot: stale)

        XCTAssertEqual(final.snapshot.searchTimingSummary, "newer")
        XCTAssertEqual(final.useLedger.papers.count, 1)
    }

    func testLegacyResetDeletesOnlyProjectsAndAutosaveOnce() async throws {
        let root = try makeTemporaryDirectory()
        let legacy = root.appendingPathComponent("SearchSession")
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        try Data("project".utf8).write(to: legacy.appendingPathComponent("Projects/index.json"))
        try Data("autosave".utf8).write(to: legacy.appendingPathComponent("online-search.json"))
        try Data("keep".utf8).write(to: root.appendingPathComponent("library.json"))

        let store = SearchHistoryStore(root: root.appendingPathComponent("SearchHistory"), legacyRoot: legacy)
        try await store.bootstrap()
        try Data("new legacy".utf8).write(to: legacy.appendingPathComponent("online-search.json"))
        try await store.bootstrap()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Projects").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("online-search.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
    }

    func testFailedSaveLeavesPreviousRecordReadable() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let store = SearchHistoryStore(root: root, legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession"))
        try await store.bootstrap()
        let record = makeRecord(query: "gut", works: [makeWork()], date: Date())
        _ = try await store.save(record)
        let indexURL = root.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)

        var changed = record
        changed.displayQuery = "changed"
        await XCTAssertThrowsErrorAsync { _ = try await store.save(changed) }
        try FileManager.default.removeItem(at: indexURL)
        let restored = try await store.loadRecord(id: record.id)
        XCTAssertEqual(restored, record)
    }
}

func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
```

- [ ] **Step 2: Run the store tests and verify they fail**

Run:

```bash
swift test --filter SearchHistoryStoreTests
```

Expected: compilation fails because `SearchHistoryStore` does not exist.

- [ ] **Step 3: Implement the actor-backed store**

Create `Sources/RagBio/SearchHistoryStore.swift`. Use `Data.write(options: .atomic)`, always save a record before its index summary, and implement these exact operations:

```swift
import Foundation

enum SearchHistoryStoreError: LocalizedError {
    case recordNotFound
    case corruptRecord

    var errorDescription: String? {
        switch self {
        case .recordNotFound: return "Search history was not found."
        case .corruptRecord: return "This search history is damaged and could not be opened."
        }
    }
}

actor SearchHistoryStore {
    private let root: URL
    private let records: URL
    private let indexURL: URL
    private let legacyResetMarkerURL: URL
    private let legacyRoot: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(root customRoot: URL? = nil, legacyRoot customLegacyRoot: URL? = nil) {
        let applicationRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RagBio", isDirectory: true)
        root = customRoot ?? applicationRoot.appendingPathComponent("SearchHistory", isDirectory: true)
        records = root.appendingPathComponent("records", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        legacyResetMarkerURL = root.appendingPathComponent(".legacy-reset-v1")
        legacyRoot = customLegacyRoot ?? applicationRoot.appendingPathComponent("SearchSession", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func bootstrap() throws {
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        var index = try readIndexOrRebuild()
        if FileManager.default.fileExists(atPath: legacyResetMarkerURL.path) {
            if index.legacyResetVersion != 1 {
                index.legacyResetVersion = 1
                try writeIndex(index)
            }
            return
        }
        try? FileManager.default.removeItem(at: legacyRoot.appendingPathComponent("Projects", isDirectory: true))
        try? FileManager.default.removeItem(at: legacyRoot.appendingPathComponent("online-search.json"))
        try Data("1".utf8).write(to: legacyResetMarkerURL, options: .atomic)
        index.legacyResetVersion = 1
        try writeIndex(index)
    }

    func loadIndex() throws -> SearchHistoryIndex { try readIndexOrRebuild() }

    func loadRecord(id: UUID) throws -> SearchHistoryRecord {
        guard let data = try? Data(contentsOf: recordURL(id)) else {
            try? omitFromIndex(id: id)
            throw SearchHistoryStoreError.recordNotFound
        }
        guard let record = try? decoder.decode(SearchHistoryRecord.self, from: data),
              record.schemaVersion == SearchHistoryRecord.currentSchemaVersion else {
            try? omitFromIndex(id: id)
            throw SearchHistoryStoreError.corruptRecord
        }
        return record
    }

    func record(normalizedQuery: String) throws -> SearchHistoryRecord? {
        let index = try readIndexOrRebuild()
        guard let id = index.summaries.first(where: { $0.normalizedQuery == normalizedQuery })?.id else { return nil }
        return try loadRecord(id: id)
    }

    @discardableResult
    func save(_ record: SearchHistoryRecord) throws -> SearchHistoryIndex {
        let url = recordURL(record.id)
        let previousRecordData = try? Data(contentsOf: url)
        do {
            try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
            try encoder.encode(record).write(to: url, options: .atomic)
            var index = try readIndexOrRebuild()
            let duplicateIDs = index.summaries
                .filter { $0.normalizedQuery == record.normalizedQuery && $0.id != record.id }
                .map(\.id)
            index.summaries.removeAll { $0.id == record.id || $0.normalizedQuery == record.normalizedQuery }
            index.summaries.append(summary(record))
            index.summaries.sort { $0.lastSuccessfulSearchAt > $1.lastSuccessfulSearchAt }
            index.lastOpenedHistoryID = record.id
            try writeIndex(index)
            for id in duplicateIDs { try? FileManager.default.removeItem(at: recordURL(id)) }
            return index
        } catch {
            if let previousRecordData {
                try? previousRecordData.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    func setUse(historyID: UUID, work: Work, isUsed: Bool) throws -> SearchHistoryRecord {
        var record = try loadRecord(id: historyID)
        if isUsed { record.useLedger.mark(work) } else { record.useLedger.remove(work) }
        _ = try save(record)
        return record
    }

    func updateSnapshot(historyID: UUID, snapshot: SearchHistorySnapshot) throws -> SearchHistoryRecord {
        var record = try loadRecord(id: historyID)
        guard snapshot.revision >= record.snapshot.revision else { return record }
        record.snapshot = snapshot
        _ = try save(record)
        return record
    }

    func setLastOpened(_ id: UUID?) throws -> SearchHistoryIndex {
        var index = try readIndexOrRebuild()
        index.lastOpenedHistoryID = id
        try writeIndex(index)
        return index
    }

    func delete(id: UUID) throws -> SearchHistoryIndex {
        var index = try readIndexOrRebuild()
        index.summaries.removeAll { $0.id == id }
        if index.lastOpenedHistoryID == id { index.lastOpenedHistoryID = nil }
        try writeIndex(index)
        try? FileManager.default.removeItem(at: recordURL(id))
        return index
    }

    private func readIndexOrRebuild() throws -> SearchHistoryIndex {
        if let data = try? Data(contentsOf: indexURL),
           let index = try? decoder.decode(SearchHistoryIndex.self, from: data),
           index.schemaVersion == SearchHistoryIndex.currentSchemaVersion {
            return index
        }
        let rebuilt = try rebuildIndex()
        try writeIndex(rebuilt)
        return rebuilt
    }

    private func rebuildIndex() throws -> SearchHistoryIndex {
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(at: records, includingPropertiesForKeys: nil)
        let decoded = urls.compactMap { url -> SearchHistoryRecord? in
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(SearchHistoryRecord.self, from: data),
                  record.schemaVersion == SearchHistoryRecord.currentSchemaVersion else { return nil }
            return record
        }.sorted { $0.lastSuccessfulSearchAt > $1.lastSuccessfulSearchAt }
        var seenQueries = Set<String>()
        let summaries = decoded.compactMap { record -> SearchHistorySummary? in
            guard seenQueries.insert(record.normalizedQuery).inserted else { return nil }
            return summary(record)
        }
        return SearchHistoryIndex(
            schemaVersion: SearchHistoryIndex.currentSchemaVersion,
            summaries: summaries,
            lastOpenedHistoryID: nil,
            legacyResetVersion: FileManager.default.fileExists(atPath: legacyResetMarkerURL.path) ? 1 : 0
        )
    }

    private func summary(_ record: SearchHistoryRecord) -> SearchHistorySummary {
        SearchHistorySummary(
            id: record.id,
            displayQuery: record.displayQuery,
            normalizedQuery: record.normalizedQuery,
            createdAt: record.createdAt,
            lastSuccessfulSearchAt: record.lastSuccessfulSearchAt,
            paperCount: record.snapshot.rankedWorks.count,
            useCount: record.useLedger.papers.count
        )
    }

    private func writeIndex(_ index: SearchHistoryIndex) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(index).write(to: indexURL, options: .atomic)
    }

    private func omitFromIndex(id: UUID) throws {
        var index = try readIndexOrRebuild()
        index.summaries.removeAll { $0.id == id }
        if index.lastOpenedHistoryID == id { index.lastOpenedHistoryID = nil }
        try writeIndex(index)
    }

    private func recordURL(_ id: UUID) -> URL {
        records.appendingPathComponent("\(id.uuidString).json")
    }
}
```

- [ ] **Step 4: Run store and model tests**

Run:

```bash
swift test --filter SearchHistory
```

Expected: all Task 1 and Task 2 tests pass, including restoration of the previous record after the deliberately blocked index write.

- [ ] **Step 5: Commit persistence**

```bash
git add Sources/RagBio/SearchHistoryStore.swift Tests/RagBioTests/SearchHistoryStoreTests.swift
git commit -m "persist AI search history records"
```

---

### Task 3: Replace Project and Autosave Ownership in `SearchStore`

**Files:**
- Modify: `Sources/RagBio/SearchStore.swift`
- Create: `Tests/RagBioTests/SearchStoreHistoryTests.swift`
- Delete: `Sources/RagBio/OnlineSearchSessionStore.swift`
- Delete: `Sources/RagBio/OnlineSearchProjectStore.swift`

**Interfaces:**
- Consumes: `SearchHistoryStore` and all Task 1 models.
- Produces: `historySummaries`, `currentHistoryID`, `currentHistoryRecord`, `historyErrorMessage`, `isRefreshingHistory`, `loadInitialHistory()`, `openHistory(_:)`, and `deleteHistory(_:)`.
- Produces: `makeHistorySnapshot(displayQuery:revision:)` and `restoreHistoryRecord(_:)` as internal testable methods.

- [ ] **Step 1: Write restore and deletion integration tests**

Create `Tests/RagBioTests/SearchStoreHistoryTests.swift` with `@MainActor` tests:

```swift
import XCTest
@testable import RagBio

@MainActor
final class SearchStoreHistoryTests: XCTestCase {
    func testOpeningHistoryRestoresSnapshotWithoutStartingSearch() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(root: root.appendingPathComponent("SearchHistory"), legacyRoot: root.appendingPathComponent("SearchSession"))
        try await historyStore.bootstrap()
        let record = makeRecord(query: "gut", works: [makeWork()], date: Date())
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)

        await store.openHistory(record.id)

        XCTAssertEqual(store.query, "gut")
        XCTAssertEqual(store.works.map(\.id), record.snapshot.allWorks.map(\.id))
        XCTAssertEqual(store.currentHistoryID, record.id)
        XCTAssertFalse(store.isLoading)
    }

    func testDeletingCurrentHistoryReturnsEmptyState() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(root: root.appendingPathComponent("SearchHistory"), legacyRoot: root.appendingPathComponent("SearchSession"))
        try await historyStore.bootstrap()
        let record = makeRecord(query: "gut", works: [makeWork()], date: Date())
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(record.id)

        await store.deleteHistory(record.id)

        XCTAssertNil(store.currentHistoryID)
        XCTAssertTrue(store.works.isEmpty)
        XCTAssertEqual(store.query, "")
    }
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run:

```bash
swift test --filter SearchStoreHistoryTests
```

Expected: compilation fails because the new `SearchStore` history API does not exist.

- [ ] **Step 3: Replace Project/session dependencies and startup restore**

In `SearchStore.swift`:

1. Remove `searchMode`, `projectSummaries`, `currentProjectID`, `projectErrorMessage`, `onlineSessionStore`, `projectStore`, all Project commands, `restoreOnlineSearchSessionIfAvailable`, and `saveOnlineSearchSession`.
2. Add these properties and initializer parameters:

```swift
@Published private(set) var historySummaries: [SearchHistorySummary] = []
@Published private(set) var currentHistoryID: UUID?
@Published private(set) var currentHistoryRecord: SearchHistoryRecord?
@Published private(set) var historyErrorMessage: String?
@Published private(set) var isRefreshingHistory = false
@Published private(set) var exportMessage: String?

private let historyStore: SearchHistoryStore
private var historyRevision = 0

init(
    client: OpenAlexClient = OpenAlexClient(),
    fullTextService: FullTextService = FullTextService(),
    aiQueryPlanner: AIQueryPlanner = AIQueryPlanner(),
    historyStore: SearchHistoryStore = SearchHistoryStore(),
    restoreOnInit: Bool = true
) {
    self.client = client
    self.fullTextService = fullTextService
    self.aiQueryPlanner = aiQueryPlanner
    self.historyStore = historyStore
    if restoreOnInit {
        Task { await loadInitialHistory() }
    }
}
```

3. Implement startup and explicit open without any call to `search()`:

```swift
func loadInitialHistory() async {
    do {
        try await historyStore.bootstrap()
        let index = try await historyStore.loadIndex()
        historySummaries = index.summaries
        guard let id = index.lastOpenedHistoryID else { return }
        await openHistory(id)
    } catch {
        historyErrorMessage = error.localizedDescription
    }
}

func openHistory(_ id: UUID) async {
    aiEnhancementTask?.cancel()
    aiEnhancementTask = nil
    searchGeneration &+= 1
    isLoading = false
    isRefreshingHistory = false
    do {
        let record = try await historyStore.loadRecord(id: id)
        restoreHistoryRecord(record)
        let index = try await historyStore.setLastOpened(id)
        historySummaries = index.summaries
    } catch {
        historyErrorMessage = error.localizedDescription
    }
}

func deleteHistory(_ id: UUID) async {
    do {
        let index = try await historyStore.delete(id: id)
        historySummaries = index.summaries
        guard currentHistoryID == id else { return }
        clearVisibleSearch()
    } catch {
        historyErrorMessage = error.localizedDescription
    }
}
```

4. Implement snapshot conversion and restoration with the exact persisted fields:

```swift
func makeHistorySnapshot(displayQuery: String, revision: Int) -> SearchHistorySnapshot {
    SearchHistorySnapshot(
        revision: revision,
        displayQuery: displayQuery,
        retrievalQuery: lastQuery,
        sort: sort,
        fromYearEnabled: fromYearEnabled,
        fromYear: fromYear,
        openAccessOnly: openAccessOnly,
        allWorks: works,
        rankedWorks: aiRankedWorks,
        totalCount: totalCount,
        currentPage: currentPage,
        selectedWorkID: selection,
        lastAIPlan: lastAIPlan,
        aiReasons: aiReasons,
        aiScores: aiScores,
        aiEvidenceLevels: aiEvidenceLevels,
        aiSearchNotice: aiSearchNotice,
        pubMedNotice: pubMedNotice,
        searchTimingSummary: searchTimingSummary,
        fullTextReviewSummaries: fullTextReviewSummaries,
        articleSummaries: articleSummaries,
        currentEvidenceTable: currentEvidenceTable,
        currentFieldScanReport: currentFieldScanReport
    )
}

func restoreHistoryRecord(_ record: SearchHistoryRecord) {
    let snapshot = record.snapshot
    query = record.displayQuery
    sort = snapshot.sort
    fromYearEnabled = snapshot.fromYearEnabled
    fromYear = snapshot.fromYear
    openAccessOnly = snapshot.openAccessOnly
    works = snapshot.allWorks
    aiRankedWorks = snapshot.rankedWorks
    totalCount = snapshot.totalCount
    currentPage = snapshot.currentPage
    selection = snapshot.selectedWorkID
    lastQuery = snapshot.retrievalQuery
    lastAIPlan = snapshot.lastAIPlan
    aiReasons = snapshot.aiReasons
    aiScores = snapshot.aiScores
    aiEvidenceLevels = snapshot.aiEvidenceLevels
    aiSearchNotice = snapshot.aiSearchNotice
    pubMedNotice = snapshot.pubMedNotice
    searchTimingSummary = snapshot.searchTimingSummary
    fullTextReviewSummaries = snapshot.fullTextReviewSummaries
    articleSummaries = snapshot.articleSummaries
    currentEvidenceTable = snapshot.currentEvidenceTable
    currentFieldScanReport = snapshot.currentFieldScanReport
    currentHistoryID = record.id
    currentHistoryRecord = record
    historyRevision = snapshot.revision
    decisionFilter = decisionFilter == .use ? .use : .all
    applyUseLedgerToVisibleWorks(record.useLedger)
    evidence = EvidenceExtractor.extract(query: snapshot.retrievalQuery, works: works)
    fullTextState = .idle
    fullTextDocument = nil
    passageHits = []
    corpusState = .idle
    corpusDocuments = [:]
    corpusHits = []
    isLoading = false
    errorMessage = nil
}
```

5. Implement synchronous `clearVisibleSearch()` to cancel work, increment `searchGeneration`, clear query/results/selection/AI artifacts, and set `currentHistoryID` and `currentHistoryRecord` to nil. `deleteHistory(_:)` has already cleared `lastOpenedHistoryID` in the actor, so this helper performs no second disk write.

- [ ] **Step 4: Replace persistence call sites with one scheduling helper**

Replace each old `saveOnlineSearchSession()` call with:

```swift
private func scheduleCompletedStageSave() {
    guard let record = currentHistoryRecord else { return }
    let generation = searchGeneration
    historyRevision &+= 1
    let snapshot = makeHistorySnapshot(
        displayQuery: record.displayQuery,
        revision: historyRevision
    )
    Task { [weak self] in
        await self?.persistCurrentStage(snapshot, expectedGeneration: generation)
    }
}

func persistCurrentStage(
    _ snapshot: SearchHistorySnapshot,
    expectedGeneration: Int
) async {
    guard expectedGeneration == searchGeneration,
          let historyID = currentHistoryID else { return }
    do {
        let record = try await historyStore.updateSnapshot(
            historyID: historyID,
            snapshot: snapshot
        )
        guard expectedGeneration == searchGeneration else { return }
        currentHistoryRecord = record
        let index = try await historyStore.loadIndex()
        historySummaries = index.summaries
    } catch {
        historyErrorMessage = "Search completed, but history could not be saved."
    }
}
```

At this task boundary the helper performs a real write for an opened record and correctly does nothing before the first usable stage has created a history record. Task 4 adds creation and refresh semantics without changing this signature.

- [ ] **Step 5: Delete old store files and run tests**

Delete `OnlineSearchSessionStore.swift` and `OnlineSearchProjectStore.swift`, then run:

```bash
swift test --filter SearchStoreHistoryTests
swift build
```

Expected: the two integration tests pass and the app builds with no references to `OnlineSearchProject`, `OnlineSearchSessionSnapshot`, `projectStore`, or `onlineSessionStore`.

- [ ] **Step 6: Commit the ownership migration**

```bash
git add Sources/RagBio/SearchStore.swift Sources/RagBio/OnlineSearchSessionStore.swift Sources/RagBio/OnlineSearchProjectStore.swift Tests/RagBioTests/SearchStoreHistoryTests.swift
git commit -m "replace projects with search history state"
```

---

### Task 4: Persist Completed AI Stages and Protect Refreshes

**Files:**
- Modify: `Sources/RagBio/SearchStore.swift`
- Modify: `Tests/RagBioTests/SearchStoreHistoryTests.swift`

**Interfaces:**
- Consumes: Task 3 history state.
- Produces: async `beginHistorySearch(displayQuery:)`, `commitFirstUsableHistoryStage(displayQuery:startedAt:generation:)`, and revision-checked `persistCurrentStage(_:expectedGeneration:)`.
- Guarantees: only the current generation writes; same-query old state survives until usable results; later ranking/full-text stages update the same record.

- [ ] **Step 1: Add refresh protection tests**

Append tests that exercise internal state helpers without network:

```swift
func testSameQueryRefreshKeepsOldResultsUntilFirstUsableCommit() async throws {
    let root = try makeTemporaryDirectory()
    let historyStore = SearchHistoryStore(root: root.appendingPathComponent("SearchHistory"), legacyRoot: root.appendingPathComponent("SearchSession"))
    try await historyStore.bootstrap()
    let old = makeRecord(query: "Gut  Microbiota", works: [makeWork(id: "https://openalex.org/W1")], date: Date(timeIntervalSince1970: 1))
    _ = try await historyStore.save(old)
    let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
    await store.openHistory(old.id)

    let generation = await store.beginHistorySearch(displayQuery: "gut microbiota")

    XCTAssertTrue(store.isRefreshingHistory)
    XCTAssertEqual(store.works.first?.shortID, "W1")
    XCTAssertTrue(store.isCurrentSearchGeneration(generation))
}

func testStaleGenerationCannotPersistStage() async throws {
    let root = try makeTemporaryDirectory()
    let historyStore = SearchHistoryStore(root: root.appendingPathComponent("SearchHistory"), legacyRoot: root.appendingPathComponent("SearchSession"))
    try await historyStore.bootstrap()
    let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
    let stale = await store.beginHistorySearch(displayQuery: "first")
    let snapshot = store.makeHistorySnapshot(displayQuery: "first", revision: 1)
    _ = await store.beginHistorySearch(displayQuery: "second")

    await store.persistCurrentStage(snapshot, expectedGeneration: stale)

    let index = try await historyStore.loadIndex()
    XCTAssertTrue(index.summaries.isEmpty)
}
```

- [ ] **Step 2: Run the tests and verify failure**

Run:

```bash
swift test --filter SearchStoreHistoryTests
```

Expected: compilation fails for the missing generation and history-stage helpers.

- [ ] **Step 3: Make `search()` AI-only and preserve the prior snapshot**

At the beginning of `search()`:

```swift
let displayQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
guard !displayQuery.isEmpty else { return }
let generation = await beginHistorySearch(displayQuery: displayQuery)
guard generation == searchGeneration else { return }
let searchStartedAt = Date()
```

Implement:

```swift
@discardableResult
func beginHistorySearch(displayQuery: String) async -> Int {
    aiEnhancementTask?.cancel()
    aiEnhancementTask = nil
    searchGeneration &+= 1
    let generation = searchGeneration
    let normalized = SearchQueryIdentity.normalize(displayQuery)
    let prior: SearchHistoryRecord?
    if currentHistoryRecord?.normalizedQuery == normalized {
        prior = currentHistoryRecord
    } else {
        prior = try? await historyStore.record(normalizedQuery: normalized)
    }
    guard generation == searchGeneration else { return generation }
    if let prior {
        restoreHistoryRecord(prior)
        query = displayQuery
        isRefreshingHistory = true
    } else {
        isRefreshingHistory = false
        clearSearchResultsForDifferentQuery()
    }
    errorMessage = nil
    historyErrorMessage = nil
    return generation
}

func isCurrentSearchGeneration(_ generation: Int) -> Bool {
    generation == searchGeneration
}

private func clearSearchResultsForDifferentQuery() {
    currentHistoryID = nil
    currentHistoryRecord = nil
    works = []
    aiRankedWorks = []
    totalCount = 0
    currentPage = 1
    selection = nil
    evidence = []
    scanDecisions = [:]
    currentEvidenceTable = nil
    currentFieldScanReport = nil
    lastAIPlan = nil
    aiReasons = [:]
    aiScores = [:]
    aiEvidenceLevels = [:]
    aiSearchNotice = nil
    pubMedNotice = nil
    fullTextReviewSummaries = [:]
    articleSummaries = [:]
}

private func finishHistorySearchFailure(
    generation: Int,
    message: String?,
    cancelled: Bool = false
) {
    guard generation == searchGeneration else { return }
    isLoading = false
    isRefreshingHistory = false
    if !cancelled { errorMessage = message }
}
```

Use `finishHistorySearchFailure` for the unconfigured-provider guard and every top-level search catch. Treat an empty candidate array as a zero-result failure before mutating All. Cancellation caused by opening another history remains silent. This leaves a same-query record unchanged and leaves a different-query attempt as an unsaved empty state.

Remove the `OpenAlexQueryNormalizer.normalize(cleanQuery)` preflight and the Keyword Search branch entirely; the AI planner receives `displayQuery` directly. Keep the previous All visible for identical input while planning/fetching; for a different input, show the empty loading state. Remove the current early `resetScanArtifactsForNewSearch()` call. After candidates become usable, clear only derived Evidence Table/Field Scan state; never clear the record's Use ledger.

- [ ] **Step 4: Commit the first usable stage before replacing history**

Immediately after local ranking creates non-empty `aiRankedWorks`, build a record using the prior matching record's `id`, `createdAt`, and `useLedger`; otherwise create a new UUID and empty ledger. Assign the new UI state, then call:

```swift
await commitFirstUsableHistoryStage(
    displayQuery: displayQuery,
    startedAt: searchStartedAt,
    generation: generation
)
```

Implement the helper:

```swift
func commitFirstUsableHistoryStage(
    displayQuery: String,
    startedAt: Date,
    generation: Int
) async {
    guard generation == searchGeneration, !aiRankedWorks.isEmpty else { return }
    let normalized = SearchQueryIdentity.normalize(displayQuery)
    do {
        let prior = try await historyStore.record(normalizedQuery: normalized)
        guard generation == searchGeneration else { return }
        historyRevision = max(historyRevision, prior?.snapshot.revision ?? 0) + 1
        let record = SearchHistoryRecord(
            schemaVersion: SearchHistoryRecord.currentSchemaVersion,
            id: prior?.id ?? UUID(),
            displayQuery: displayQuery,
            normalizedQuery: normalized,
            createdAt: prior?.createdAt ?? startedAt,
            lastSuccessfulSearchAt: Date(),
            snapshot: makeHistorySnapshot(
                displayQuery: displayQuery,
                revision: historyRevision
            ),
            useLedger: prior?.useLedger ?? UseLedger()
        )
        let index = try await historyStore.save(record)
        guard generation == searchGeneration else { return }
        currentHistoryID = record.id
        currentHistoryRecord = record
        historySummaries = index.summaries
        isRefreshingHistory = false
        applyUseLedgerToVisibleWorks(record.useLedger)
    } catch {
        if let old = currentHistoryRecord { restoreHistoryRecord(old) }
        historyErrorMessage = "Search completed, but history could not be saved."
        isRefreshingHistory = false
    }
}
```

- [ ] **Step 5: Save later completed stages to the same record**

Keep Task 3's `scheduleCompletedStageSave()` and `persistCurrentStage(_:expectedGeneration:)` signatures unchanged. Call `scheduleCompletedStageSave()` only after these completed state transitions: local candidates, coarse AI ranking, evidence reranking, page selection, full-text summary completion, article summary completion, Evidence Table completion, and Field Scan completion. The helper captures the snapshot and monotonically increasing revision before creating its Task; `SearchHistoryStore.updateSnapshot` ignores an older revision that reaches the actor late and preserves the actor's latest Use ledger. Existing generation checks remain before every call. Cancellation and all catch paths return without scheduling a save.

- [ ] **Step 6: Run tests and build**

Run:

```bash
swift test --filter SearchStoreHistoryTests
swift build
```

Expected: all history integration tests pass; the compiler finds no Keyword Search branch in `SearchStore.search()`.

- [ ] **Step 7: Commit staged persistence**

```bash
git add Sources/RagBio/SearchStore.swift Tests/RagBioTests/SearchStoreHistoryTests.swift
git commit -m "save completed AI search stages"
```

---

### Task 5: Connect the Persistent Use Ledger to All and Use Filters

**Files:**
- Modify: `Sources/RagBio/SearchStore.swift`
- Modify: `Tests/RagBioTests/SearchStoreHistoryTests.swift`

**Interfaces:**
- Consumes: `SearchHistoryRecord.useLedger` and `SearchHistoryStore.setUse`.
- Produces: `setScanDecision(_:for:)`, `decision(for:)`, `filteredWorks`, and `hasMarkedUseWorks` backed by the persistent ledger.

- [ ] **Step 1: Add Use persistence tests**

Append:

```swift
func testUseSurvivesRefreshWhenPaperDisappearsFromAll() async throws {
    let root = try makeTemporaryDirectory()
    let historyStore = SearchHistoryStore(root: root.appendingPathComponent("SearchHistory"), legacyRoot: root.appendingPathComponent("SearchSession"))
    try await historyStore.bootstrap()
    var ledger = UseLedger()
    let used = makeWork(id: "https://openalex.org/W1")
    ledger.mark(used, at: Date())
    let refreshed = makeRecord(query: "gut", works: [makeWork(id: "https://openalex.org/W2", doi: "10.1000/new")], date: Date(), useLedger: ledger)
    _ = try await historyStore.save(refreshed)
    let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
    await store.openHistory(refreshed.id)

    store.decisionFilter = .use

    XCTAssertEqual(store.filteredWorks.map(\.shortID), ["W1"])
    XCTAssertEqual(store.decision(for: used), .use)
}

func testUseWriteFailureRestoresPreviousVisibleDecision() async throws {
    let root = try makeTemporaryDirectory()
    let historyStore = SearchHistoryStore(root: root.appendingPathComponent("SearchHistory"), legacyRoot: root.appendingPathComponent("SearchSession"))
    try await historyStore.bootstrap()
    let work = makeWork()
    let record = makeRecord(query: "gut", works: [work], date: Date())
    _ = try await historyStore.save(record)
    let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
    await store.openHistory(record.id)
    try FileManager.default.removeItem(at: root.appendingPathComponent("SearchHistory/records"))
    try Data("blocked".utf8).write(to: root.appendingPathComponent("SearchHistory/records"))

    await store.setUse(true, for: work)

    XCTAssertEqual(store.decision(for: work), .unreviewed)
    XCTAssertNotNil(store.historyErrorMessage)
}
```

- [ ] **Step 2: Run the tests and verify the current behavior fails**

Run:

```bash
swift test --filter SearchStoreHistoryTests
```

Expected: the missing-paper test fails because current filtering only examines `works`, and the write-failure API is absent.

- [ ] **Step 3: Make Use changes actor-serialized and reversible**

Implement an async core method and keep the existing button-compatible wrapper:

```swift
func setScanDecision(_ decision: ScanDecision, for work: Work) {
    Task { await setUse(decision == .use, for: work) }
}

func setUse(_ isUsed: Bool, for work: Work) async {
    guard let historyID = currentHistoryID else { return }
    let previous = currentHistoryRecord
    if isUsed { currentHistoryRecord?.useLedger.mark(work) }
    else { currentHistoryRecord?.useLedger.remove(work) }
    objectWillChange.send()
    do {
        let record = try await historyStore.setUse(historyID: historyID, work: work, isUsed: isUsed)
        currentHistoryRecord = record
        let index = try await historyStore.loadIndex()
        historySummaries = index.summaries
        applyUseLedgerToVisibleWorks(record.useLedger)
    } catch {
        currentHistoryRecord = previous
        applyUseLedgerToVisibleWorks(previous?.useLedger ?? UseLedger())
        historyErrorMessage = "Use could not be saved. Your previous selection was restored."
    }
}

private func applyUseLedgerToVisibleWorks(_ ledger: UseLedger) {
    var decisions: [String: ScanDecisionRecord] = [:]
    for paper in ledger.papers {
        decisions[paper.work.id] = ScanDecisionRecord(
            workID: paper.work.id,
            decision: .use,
            note: nil,
            updatedAt: paper.selectedAt
        )
    }
    for work in works where ledger.contains(work) {
        decisions[work.id] = ScanDecisionRecord(
            workID: work.id,
            decision: .use,
            note: nil,
            updatedAt: Date()
        )
    }
    scanDecisions = decisions
}
```

`decision(for:)` returns `.use` when the ledger matches the paper. `filteredWorks` returns the current All page for `.all` and `currentHistoryRecord?.useLedger.papers.map(\.work)` for `.use`. `hasMarkedUseWorks` uses the ledger count. Remove any remaining Maybe/Exclude assumptions from these paths.

- [ ] **Step 4: Run tests and build**

Run:

```bash
swift test --filter SearchStoreHistoryTests
swift build
```

Expected: Use remains visible when absent from All, reappearing papers are recognized by stable keys, and failed writes restore the prior visible state.

- [ ] **Step 5: Commit Use integration**

```bash
git add Sources/RagBio/SearchStore.swift Tests/RagBioTests/SearchStoreHistoryTests.swift
git commit -m "preserve Use across search refreshes"
```

---

### Task 6: Build the AI-Only Search Field and History Dropdown

**Files:**
- Create: `Sources/RagBio/SearchHistoryViews.swift`
- Modify: `Sources/RagBio/ContentView.swift`
- Modify: `Sources/RagBio/AIProvider.swift`
- Modify: `Sources/RagBio/RagBioApp.swift`

**Interfaces:**
- Consumes: `SearchStore.historySummaries`, `openHistory(_:)`, `deleteHistory(_:)`, `search()`, `query`, `isLoading`, and `isRefreshingHistory`.
- Produces: `SearchHistoryField` with local pending-deletion state.

- [ ] **Step 1: Create the focused history field**

Create `SearchHistoryViews.swift` with a `SearchHistoryField` that:

```swift
import SwiftUI

struct SearchHistoryField: View {
    @ObservedObject var store: SearchStore
    @FocusState private var focused: Bool
    @State private var deletion: SearchHistorySummary?

    private var filtered: [SearchHistorySummary] {
        let needle = SearchQueryIdentity.normalize(store.query)
        guard !needle.isEmpty else { return store.historySummaries }
        return store.historySummaries.filter {
            SearchQueryIdentity.normalize($0.displayQuery).contains(needle)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            TextField("描述你想找什么…", text: $store.query)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .focused($focused)
                .onSubmit { runSearch() }
            Button("检索") { runSearch() }
                .buttonStyle(.borderedProminent)
                .disabled(store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLoading)
        }
        .padding(3)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(focused ? Color.accentColor : Color.secondary.opacity(0.25)))
        .overlay(alignment: .top) {
            if focused, !filtered.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { summary in
                            Button {
                                focused = false
                                Task { await store.openHistory(summary.id) }
                            } label: {
                                Text(summary.displayQuery)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .frame(height: 38)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Delete Search History", role: .destructive) {
                                    if summary.useCount == 0 {
                                        Task { await store.deleteHistory(summary.id) }
                                    } else {
                                        deletion = summary
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                }
                .frame(height: 266)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .offset(y: 44)
                .shadow(radius: 8, y: 4)
                .zIndex(20)
            }
        }
        .zIndex(20)
        .alert("Delete Search History?", isPresented: Binding(
            get: { deletion != nil },
            set: { if !$0 { deletion = nil } }
        ), presenting: deletion) { summary in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await store.deleteHistory(summary.id) }
            }
        } message: { summary in
            Text("This also deletes \(summary.useCount) saved Use selection(s) from this search history. This cannot be undone.")
        }
    }

    private func runSearch() {
        focused = false
        Task { await store.search() }
    }
}
```

- [ ] **Step 2: Replace the old search header controls**

In `ContentView.swift`:

- remove `ProjectBar` and its AppKit prompt/confirmation helpers;
- remove the segmented `SearchMode` picker;
- replace the old `TextField` and bottom search button with `SearchHistoryField(store: store)`;
- retain sort, open-access, and year dropdown controls below it;
- show `Refreshing…` while `store.isRefreshingHistory` is true;
- show `store.historyErrorMessage` and `store.exportMessage` as non-blocking status labels;
- remove the root `.task` that calls `store.search()` when restored query text exists;
- keep only `.all` and `.use` in the Scan filter.

- [ ] **Step 3: Remove the obsolete search mode type and conditionals**

Delete `SearchMode` from `AIProvider.swift`. Replace UI and ranking checks of `store.searchMode == .ai` with the direct AI values, and simplify `ensureSearchIsActive` to:

```swift
private func ensureSearchIsActive(_ generation: Int) throws {
    guard generation == searchGeneration else { throw CancellationError() }
}
```

Update every call to pass only the generation. Keep the Command-menu action in `RagBioApp.swift`; it calls the same AI-only `store.search()` method.

- [ ] **Step 4: Build and perform the focused UI smoke test**

Run:

```bash
swift build
swift run RagBio
```

Expected manual checks:

1. No Project bar and no Keyword/AI segmented picker.
2. Search field has no left icon area and has a visible right `检索` button.
3. Return and the button trigger the same AI search.
4. Empty focus shows newest history first; typing filters rows without performing a search.
5. The dropdown stays about seven rows tall and scrolls.
6. Clicking a row restores instantly without new loading or network notices.
7. Right-click delete is direct without Use and English-confirmed with Use.
8. Deleting the open row leaves an empty search page.

- [ ] **Step 5: Commit the AI-only history UI**

```bash
git add Sources/RagBio/SearchHistoryViews.swift Sources/RagBio/ContentView.swift Sources/RagBio/AIProvider.swift Sources/RagBio/RagBioApp.swift Sources/RagBio/SearchStore.swift
git commit -m "add AI search history interaction"
```

---

### Task 7: Add Deterministic Multi-History Use URL Export

**Files:**
- Create: `Sources/RagBio/SearchHistoryExport.swift`
- Create: `Tests/RagBioTests/SearchHistoryExportTests.swift`
- Modify: `Sources/RagBio/SearchHistoryViews.swift`
- Modify: `Sources/RagBio/ContentView.swift`
- Modify: `Sources/RagBio/SearchStore.swift`

**Interfaces:**
- Produces: `SearchHistoryExportBuilder.make(records:) -> SearchHistoryExportDocument`
- Produces: `SearchHistoryExportDocument.text`, `urlCount`, and `skippedPaperCount`
- Produces: `SearchStore.loadExportRecords(ids:)` and `presentExportStatus(_:)`
- Consumes: `SearchHistoryStore.loadRecord(id:)`

- [ ] **Step 1: Write export tests**

Create `Tests/RagBioTests/SearchHistoryExportTests.swift`:

```swift
import XCTest
@testable import RagBio

final class SearchHistoryExportTests: XCTestCase {
    func testURLPriorityIsDOIThenPubMedThenPublisherThenOpenAlex() {
        XCTAssertEqual(SearchHistoryURLResolver.url(for: makeWork())?.absoluteString, "https://doi.org/10.1000/example")
        XCTAssertEqual(SearchHistoryURLResolver.url(for: makeWork(doi: nil))?.absoluteString, "https://pubmed.ncbi.nlm.nih.gov/123/")
        XCTAssertEqual(SearchHistoryURLResolver.url(for: makeWork(doi: nil, pmid: nil))?.absoluteString, "https://publisher.example/article")
        XCTAssertEqual(SearchHistoryURLResolver.url(for: makeWork(doi: nil, pmid: nil, publisherURL: nil))?.absoluteString, "https://openalex.org/W1")
        XCTAssertEqual(SearchHistoryURLResolver.url(for: makeWork(doi: nil, pmid: nil, publisherURL: "https://publisher.example/paper.pdf?download=1"))?.absoluteString, "https://openalex.org/W1")
    }

    func testExportOrdersChunksOldestFirstAndDeduplicatesOnlyWithinChunk() {
        let shared = makeWork()
        var firstLedger = UseLedger(); firstLedger.mark(shared, at: Date())
        var secondLedger = UseLedger(); secondLedger.mark(shared, at: Date())
        secondLedger.mark(makeWork(id: "", doi: nil, pmid: nil, title: "No URL", publisherURL: nil), at: Date())
        let newer = makeRecord(query: "newer", works: [], date: Date(timeIntervalSince1970: 2), useLedger: secondLedger)
        let older = makeRecord(query: "older", works: [], date: Date(timeIntervalSince1970: 1), useLedger: firstLedger)

        let document = SearchHistoryExportBuilder.make(records: [newer, older])

        XCTAssertLessThan(document.text.range(of: "Query: older")!.lowerBound, document.text.range(of: "Query: newer")!.lowerBound)
        XCTAssertEqual(document.text.components(separatedBy: "https://doi.org/10.1000/example").count - 1, 2)
        XCTAssertEqual(document.urlCount, 2)
        XCTAssertEqual(document.skippedPaperCount, 1)
        XCTAssertTrue(document.text.hasSuffix("------\n"))
    }
}
```

- [ ] **Step 2: Run export tests and verify failure**

Run:

```bash
swift test --filter SearchHistoryExportTests
```

Expected: compilation fails because the export builder and resolver do not exist.

- [ ] **Step 3: Implement URL resolution and TXT rendering**

Create `SearchHistoryExport.swift`:

```swift
import Foundation

struct SearchHistoryExportDocument: Equatable {
    var text: String
    var urlCount: Int
    var skippedPaperCount: Int
}

enum SearchHistoryURLResolver {
    static func url(for work: Work) -> URL? {
        if let doi = work.normalizedDOI, !doi.isEmpty {
            return URL(string: "https://doi.org/\(doi.lowercased())")
        }
        if let pmid = work.normalizedPMID, !pmid.isEmpty {
            return URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/")
        }
        let publisher = [work.bestOpenAccessLocation?.landingPageURL, work.primaryLocation?.landingPageURL]
            .compactMap { $0 }
            .compactMap(URL.init(string:))
            .first { url in
                let value = url.absoluteString.lowercased()
                return url.pathExtension.lowercased() != "pdf"
                    && !value.contains("openalex.org/")
                    && !value.contains("doi.org/")
            }
        if let publisher { return publisher }
        let short = work.shortID
        guard short.lowercased().hasPrefix("w") else { return nil }
        return URL(string: "https://openalex.org/\(short)")
    }
}

enum SearchHistoryExportBuilder {
    static func make(records: [SearchHistoryRecord]) -> SearchHistoryExportDocument {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        var count = 0
        var skipped = 0
        for record in records.sorted(by: { $0.lastSuccessfulSearchAt < $1.lastSuccessfulSearchAt }) {
            var seen = Set<String>()
            var urls: [String] = []
            for paper in record.useLedger.papers {
                guard let value = SearchHistoryURLResolver.url(for: paper.work)?.absoluteString else {
                    skipped += 1
                    continue
                }
                if seen.insert(value).inserted { urls.append(value) }
            }
            lines.append("------")
            lines.append("Query: \(record.displayQuery)")
            lines.append("Search Time: \(formatter.string(from: record.lastSuccessfulSearchAt))")
            lines.append(contentsOf: urls)
            count += urls.count
        }
        lines.append("------")
        return SearchHistoryExportDocument(text: lines.joined(separator: "\n") + "\n", urlCount: count, skippedPaperCount: skipped)
    }
}
```

- [ ] **Step 4: Add lazy export loading to `SearchStore`**

```swift
func loadExportRecords(ids: Set<UUID>) async -> SearchHistoryExportDocument {
    var records: [SearchHistoryRecord] = []
    for id in ids {
        if let record = try? await historyStore.loadRecord(id: id), !record.useLedger.papers.isEmpty {
            records.append(record)
        }
    }
    return SearchHistoryExportBuilder.make(records: records)
}

func presentExportStatus(_ document: SearchHistoryExportDocument) {
    exportMessage = "Exported \(document.urlCount) URLs. Skipped \(document.skippedPaperCount) papers without a usable URL."
}
```

- [ ] **Step 5: Add the English modal sheet and native Save panel**

Add `import AppKit` and `import UniformTypeIdentifiers` to `SearchHistoryViews.swift`, then add:

```swift
struct UseURLExportSheet: View {
    @ObservedObject var store: SearchStore
    @Binding var isPresented: Bool
    @State private var selectedIDs = Set<UUID>()
    @State private var document = SearchHistoryExportDocument(
        text: "",
        urlCount: 0,
        skippedPaperCount: 0
    )
    @State private var writeError: String?

    private var candidates: [SearchHistorySummary] {
        store.historySummaries.filter { $0.useCount > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Use URLs").font(.title2.bold())
            HStack {
                Button("Select All") { selectedIDs = Set(candidates.map(\.id)) }
                Button("Clear") { selectedIDs.removeAll() }
                Spacer()
                Text("\(selectedIDs.count) selected").foregroundStyle(.secondary)
            }
            List(candidates) { summary in
                Toggle(isOn: Binding(
                    get: { selectedIDs.contains(summary.id) },
                    set: { selected in
                        if selected { selectedIDs.insert(summary.id) }
                        else { selectedIDs.remove(summary.id) }
                    }
                )) {
                    HStack {
                        Text(summary.displayQuery).lineLimit(1)
                        Spacer()
                        Text("\(summary.useCount) Use")
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            if let writeError {
                Text(writeError).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Export \(document.urlCount) URLs…") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520, height: 430)
        .task {
            if let id = store.currentHistoryID,
               candidates.contains(where: { $0.id == id }) {
                selectedIDs = [id]
            }
        }
        .task(id: selectedIDs) {
            document = await store.loadExportRecords(ids: selectedIDs)
        }
    }

    private func save() {
        writeError = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "RagBio-Use-URLs.txt"
        panel.message = "Export URLs from selected search histories"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.text.write(to: url, atomically: true, encoding: .utf8)
            store.presentExportStatus(document)
            isPresented = false
        } catch {
            writeError = error.localizedDescription
        }
    }
}
```

Keep the sheet open on Save-panel cancellation or write failure. Show the write error in English. Do not add a TXT preview.

In `ScanDecisionFilterBar`, add `@State private var isExportPresented = false`, replace the current export action with `Button("Export Use URLs", systemImage: "square.and.arrow.up") { isExportPresented = true }`, and attach:

```swift
.sheet(isPresented: $isExportPresented) {
    UseURLExportSheet(store: store, isPresented: $isExportPresented)
}
```

This presents a sheet on the current RagBio window rather than a page or second window.

- [ ] **Step 6: Run export tests and smoke-test the sheet**

Run:

```bash
swift test --filter SearchHistoryExportTests
swift build
swift run RagBio
```

Expected: export tests pass; the sheet shows only histories with Use, the current eligible history is selected, zero selection disables export, the Save panel appears, cancelling is silent, and the exported file matches the approved English chunk format.

- [ ] **Step 7: Commit export**

```bash
git add Sources/RagBio/SearchHistoryExport.swift Sources/RagBio/SearchHistoryViews.swift Sources/RagBio/SearchStore.swift Sources/RagBio/ContentView.swift Tests/RagBioTests/SearchHistoryExportTests.swift
git commit -m "export Use URLs across search history"
```

---

### Task 8: Complete Regression, Corruption, and Large-History Verification

**Files:**
- Modify: `Tests/RagBioTests/SearchHistoryStoreTests.swift`
- Modify: `Tests/RagBioTests/SearchStoreHistoryTests.swift`
- Modify: `README.md` only if it still documents Projects or Keyword Search.

**Interfaces:**
- Verifies every acceptance criterion without adding a new production abstraction.

- [ ] **Step 1: Add remaining edge-case assertions**

Add focused tests for:

```swift
func testFilterChangesDoNotChangeHistoryIdentity() {
    let base = SearchQueryIdentity.normalize("gut")
    XCTAssertEqual(base, SearchQueryIdentity.normalize(" GUT "))
}

func testLargeIndexRemainsSortedWithoutLoadingRecords() async throws {
    let root = try makeTemporaryDirectory()
    let store = SearchHistoryStore(root: root.appendingPathComponent("SearchHistory"), legacyRoot: root.appendingPathComponent("SearchSession"))
    try await store.bootstrap()
    for offset in 0..<500 {
        let record = makeRecord(query: "query \(offset)", works: [], date: Date(timeIntervalSince1970: TimeInterval(offset)))
        _ = try await store.save(record)
    }
    let index = try await store.loadIndex()
    XCTAssertEqual(index.summaries.count, 500)
    XCTAssertEqual(index.summaries.first?.displayQuery, "query 499")
}
```

Also add explicit assertions that zero-result commit does not create a record, opening another history increments the generation and prevents the old stage from saving, identical query with different year/filter values replaces one summary, and a corrupt selected record reports an error while another record still opens.

- [ ] **Step 2: Run the complete automated suite**

Run:

```bash
swift test
```

Expected: all model, persistence, export, and SearchStore integration tests pass with zero failures.

- [ ] **Step 3: Run static cleanup checks**

Run:

```bash
rg -n "ProjectBar|OnlineSearchProject|OnlineSearchSessionSnapshot|Autosaved Search|SearchMode|case keyword|关键词搜索|saveOnlineSearchSession" Sources Tests
git diff --check
swift build
```

Expected: `rg` returns no production references; `git diff --check` is silent; `swift build` succeeds.

- [ ] **Step 4: Run the end-to-end restart and failure checklist**

Launch with `swift run RagBio` and verify:

1. A new AI search appears in history when first usable results arrive.
2. Closing during later enrichment and reopening restores the last saved stage without AI/network loading.
3. Refreshing identical text shows the old All plus `Refreshing…`, then replaces All and retains every Use.
4. A used paper absent from refreshed All remains under Use and exports.
5. Starting a different query hides the old All; opening history during the search cancels it and late results never replace the opened history.
6. History persists through app restart and filters quickly with at least 500 generated index entries.
7. A malformed record file does not block other history rows.
8. A malformed index rebuilds from valid records.
9. The one-time legacy reset leaves FullText cache, Library, settings, and API keys untouched.
10. Multi-history export is English, oldest-to-newest in the TXT, URL-prioritized, within-chunk deduplicated, cross-chunk repeatable, and reports skipped papers.

- [ ] **Step 5: Update stale README wording only when present**

If the `rg` command below returns lines, replace those exact README sections with a short AI Search History description; if it returns nothing, leave README unchanged:

```bash
rg -n "Project|Autosaved Search|Keyword Search|关键词搜索" README.md
```

The replacement copy is:

```markdown
### AI Search History

RagBio stores successful AI searches locally. Focusing the search field shows recent queries; selecting one restores its saved results and Use selections without rerunning the search. Repeating the same query refreshes its results while preserving accumulated Use papers.
```

- [ ] **Step 6: Commit final verification changes**

```bash
git add Tests/RagBioTests README.md
git commit -m "verify AI search history workflow"
```

---

## Final Verification Gate

Before claiming completion, invoke `superpowers:verification-before-completion` and run fresh:

```bash
swift test
swift build
git diff --check
git status --short
```

Expected:

- all tests pass;
- the app builds;
- no whitespace errors;
- only intentional user-owned pre-existing changes remain outside the implementation commits;
- `.superpowers/` visual-companion files remain local and unstaged unless the user separately asks to track them.
