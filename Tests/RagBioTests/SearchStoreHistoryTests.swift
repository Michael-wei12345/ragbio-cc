import Foundation
import Testing
@testable import RagBio

@MainActor
@Suite struct SearchStoreHistoryTests {
    @Test func openingHistoryRestoresSnapshotWithoutStartingSearch() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let record = makeRecord(query: "gut", works: [makeWork()], date: Date())
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)

        await store.openHistory(record.id)

        #expect(store.query == "gut")
        #expect(store.works.map(\.id) == record.snapshot.allWorks.map(\.id))
        #expect(store.currentHistoryID == record.id)
        #expect(!store.isLoading)
    }

    @Test func deletingCurrentHistoryReturnsEmptyState() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let record = makeRecord(query: "gut", works: [makeWork()], date: Date())
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(record.id)

        await store.deleteHistory(record.id)

        #expect(store.currentHistoryID == nil)
        #expect(store.works.isEmpty)
        #expect(store.query.isEmpty)
    }

    @Test func openingAnotherHistoryInvalidatesAllAsyncMutationGenerations() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let first = makeRecord(query: "first", works: [makeWork()], date: Date())
        let second = makeRecord(
            query: "second",
            works: [makeWork(id: "https://openalex.org/W2")],
            date: Date().addingTimeInterval(1)
        )
        _ = try await historyStore.save(first)
        _ = try await historyStore.save(second)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(first.id)
        let firstContext = store.captureHistoryMutationContext()

        await store.openHistory(second.id)
        let secondContext = store.captureHistoryMutationContext()

        #expect(firstContext.searchGeneration != secondContext.searchGeneration)
        #expect(firstContext.corpusGeneration != secondContext.corpusGeneration)
        #expect(!store.isCurrentHistoryMutationContext(firstContext))
    }

    @Test func deletingCurrentHistoryInvalidatesAsyncMutationContext() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let record = makeRecord(query: "gut", works: [makeWork()], date: Date())
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(record.id)
        let context = store.captureHistoryMutationContext()

        await store.deleteHistory(record.id)
        let clearedContext = store.captureHistoryMutationContext()

        #expect(!store.isCurrentHistoryMutationContext(context))
        #expect(context.corpusGeneration != clearedContext.corpusGeneration)
        #expect(clearedContext.historyID == nil)
    }

    @Test func sameQueryRefreshKeepsOldResultsUntilFirstUsableCommit() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let old = makeRecord(
            query: "Gut  Microbiota",
            works: [makeWork(id: "https://openalex.org/W1")],
            date: Date(timeIntervalSince1970: 1)
        )
        _ = try await historyStore.save(old)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)

        let generation = await store.beginHistorySearch(displayQuery: "gut microbiota")

        #expect(store.isRefreshingHistory)
        #expect(store.works.first?.shortID == "W1")
        #expect(store.isCurrentSearchGeneration(generation))
    }

    @Test func sameQueryRefreshPreservesEditedFiltersAndCommitsThem() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let old = makeRecord(
            query: "gut",
            works: [makeWork(id: "https://openalex.org/W1")],
            date: Date(timeIntervalSince1970: 1)
        )
        _ = try await historyStore.save(old)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)
        store.sort = .newest
        store.fromYearEnabled = true
        store.fromYear = 2017
        store.openAccessOnly = true

        let generation = await store.beginHistorySearch(displayQuery: "gut")

        #expect(store.works.first?.shortID == "W1")
        #expect(store.isRefreshingHistory)
        #expect(store.sort == .newest)
        #expect(store.fromYearEnabled)
        #expect(store.fromYear == 2017)
        #expect(store.openAccessOnly)

        let refreshed = makeWork(
            id: "https://openalex.org/W2",
            doi: "10.1000/refreshed"
        )
        var staged = old
        staged.snapshot.allWorks = [refreshed]
        staged.snapshot.rankedWorks = [refreshed]
        staged.snapshot.totalCount = 1
        staged.snapshot.selectedWorkID = refreshed.id
        staged.snapshot.sort = store.sort
        staged.snapshot.fromYearEnabled = store.fromYearEnabled
        staged.snapshot.fromYear = store.fromYear
        staged.snapshot.openAccessOnly = store.openAccessOnly
        store.restoreHistoryRecord(staged)

        await store.commitFirstUsableHistoryStage(
            displayQuery: "gut",
            startedAt: Date(timeIntervalSince1970: 10),
            generation: generation
        )

        let saved = try await historyStore.loadRecord(id: old.id)
        #expect(saved.snapshot.allWorks.map(\.shortID) == ["W2"])
        #expect(saved.snapshot.sort == .newest)
        #expect(saved.snapshot.fromYearEnabled)
        #expect(saved.snapshot.fromYear == 2017)
        #expect(saved.snapshot.openAccessOnly)
    }

    @Test func staleGenerationCannotPersistStage() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            persistenceDelay: .milliseconds(200)
        )
        try await historyStore.bootstrap()
        let record = makeRecord(query: "first", works: [makeWork()], date: Date())
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(record.id)
        let stale = await store.beginHistorySearch(displayQuery: "first")
        var snapshot = store.makeHistorySnapshot(displayQuery: "first", revision: 1)
        snapshot.searchTimingSummary = "stale"
        let pending = Task { @MainActor in
            await store.persistCurrentStage(snapshot, expectedGeneration: stale)
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(25))

        _ = await store.beginHistorySearch(displayQuery: "second")

        await pending.value

        let saved = try await historyStore.loadRecord(id: record.id)
        #expect(saved.snapshot.revision == 0)
        #expect(saved.snapshot.searchTimingSummary == nil)
    }

    @Test func refreshFindsMatchingSavedRecordWhenAnotherHistoryIsOpen() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let matching = makeRecord(
            query: "Gut  Microbiota",
            works: [makeWork(id: "https://openalex.org/W1")],
            date: Date(timeIntervalSince1970: 1)
        )
        let current = makeRecord(
            query: "unrelated",
            works: [makeWork(id: "https://openalex.org/W2")],
            date: Date(timeIntervalSince1970: 2)
        )
        _ = try await historyStore.save(matching)
        _ = try await historyStore.save(current)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(current.id)

        _ = await store.beginHistorySearch(displayQuery: " gut microbiota ")

        #expect(store.currentHistoryID == matching.id)
        #expect(store.works.first?.shortID == "W1")
        #expect(store.isRefreshingHistory)
    }

    @Test func differentQueryClearsUnrelatedResultsWithoutSaving() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let work = makeWork()
        var old = makeRecord(query: "old", works: [work], date: Date())
        old.snapshot.retrievalQuery = "old retrieval"
        old.snapshot.sort = .cited
        old.snapshot.fromYearEnabled = true
        old.snapshot.fromYear = 2018
        old.snapshot.openAccessOnly = true
        old.snapshot.lastAIPlan = AISearchPlan(
            searchQuery: "old retrieval",
            fromYear: 2018,
            openAccessOnly: true,
            sort: .cited,
            explanation: "old plan"
        )
        old.snapshot.aiSearchNotice = "old AI notice"
        old.snapshot.pubMedNotice = "old PubMed notice"
        old.snapshot.searchTimingSummary = "old timing"
        old.snapshot.aiEvidenceLevels = [work.id: "全文段落精排"]
        old.snapshot.fullTextReviewSummaries = [
            work.id: LiteratureReviewSummary(
                topic: "old topic",
                methods: "old methods",
                results: "old results",
                outlook: "old outlook",
                metrics: []
            )
        ]
        old.snapshot.articleSummaries = [work.id: "old article summary"]
        old.snapshot.currentEvidenceTable = EvidenceTable(
            id: UUID(),
            query: "old",
            generatedAt: Date(),
            basedOnWorkIDs: [work.id],
            rows: [],
            warning: nil
        )
        _ = try await historyStore.save(old)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)
        store.passageQuery = "old passage"
        store.fieldScanError = "old field scan error"
        store.fieldSummaryError = "old field summary error"
        store.translatedTitles[work.id] = "old title"
        store.translatedAbstracts[work.id] = "old abstract"
        store.translatedEvidence[work.id] = "old evidence"
        store.translatedPassages["old"] = "old passage"
        store.setTranslationVisible(true, for: work.id)

        _ = await store.beginHistorySearch(displayQuery: "new")

        #expect(store.query == "new")
        #expect(store.sort == .cited)
        #expect(store.fromYearEnabled)
        #expect(store.fromYear == 2018)
        #expect(store.openAccessOnly)
        #expect(store.currentHistoryID == nil)
        #expect(store.works.isEmpty)
        #expect(store.evidence.isEmpty)
        #expect(store.lastQuery.isEmpty)
        #expect(store.lastAIPlan == nil)
        #expect(store.aiRerankState == .idle)
        #expect(store.aiSecondRerankState == .idle)
        #expect(store.aiSearchNotice == nil)
        #expect(store.pubMedNotice == nil)
        #expect(store.searchTimingSummary == nil)
        #expect(store.fullTextState == .idle)
        #expect(store.fullTextDocument == nil)
        #expect(store.passageHits.isEmpty)
        #expect(store.passageQuery.isEmpty)
        #expect(store.corpusState == .idle)
        #expect(store.corpusDocuments.isEmpty)
        #expect(store.corpusHits.isEmpty)
        #expect(store.aiFullTextDocuments.isEmpty)
        #expect(store.fullTextReviewSummaries.isEmpty)
        #expect(store.fullTextReviewSummaryInProgress.isEmpty)
        #expect(store.fullTextReviewSummaryErrors.isEmpty)
        #expect(store.articleSummaries.isEmpty)
        #expect(store.articleSummaryInProgress.isEmpty)
        #expect(store.articleSummaryErrors.isEmpty)
        #expect(store.aiVisiblePageFullTextInProgress.isEmpty)
        #expect(store.aiVisiblePageFullTextFailures.isEmpty)
        #expect(store.currentEvidenceTable == nil)
        #expect(store.currentFieldScanReport == nil)
        #expect(store.fieldSummary == nil)
        #expect(store.fieldScanError == nil)
        #expect(store.fieldSummaryError == nil)
        #expect(store.translatedTitles.isEmpty)
        #expect(store.translatedAbstracts.isEmpty)
        #expect(store.translatedEvidence.isEmpty)
        #expect(store.translatedPassages.isEmpty)
        #expect(!store.isTranslationVisible(for: work.id))
        #expect(!store.isRefreshingHistory)
        #expect(try await historyStore.loadIndex().summaries.map(\.id) == [old.id])
    }

    @Test func firstUsableCommitReusesIdentityRevisionAndLatestUseLedger() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let work = makeWork()
        var old = makeRecord(
            query: "Gut Microbiota",
            works: [work],
            date: Date(timeIntervalSince1970: 1)
        )
        old.snapshot.revision = 4
        _ = try await historyStore.save(old)
        _ = try await historyStore.setUse(historyID: old.id, work: work, isUsed: true)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)
        let generation = await store.beginHistorySearch(displayQuery: "gut microbiota")
        let newWork = makeWork(id: "https://openalex.org/W2")
        var staged = old
        staged.displayQuery = "gut microbiota"
        staged.snapshot.displayQuery = "gut microbiota"
        staged.snapshot.allWorks = [newWork]
        staged.snapshot.rankedWorks = [newWork]
        staged.snapshot.totalCount = 1
        staged.snapshot.selectedWorkID = newWork.id
        store.restoreHistoryRecord(staged)

        await store.commitFirstUsableHistoryStage(
            displayQuery: "gut microbiota",
            startedAt: Date(timeIntervalSince1970: 10),
            generation: generation
        )

        let saved = try await historyStore.loadRecord(id: old.id)
        #expect(saved.id == old.id)
        #expect(saved.createdAt == old.createdAt)
        #expect(saved.snapshot.revision == 5)
        #expect(saved.snapshot.allWorks.map(\.shortID) == ["W2"])
        #expect(saved.snapshot.rankedWorks.map(\.shortID) == ["W2"])
        #expect(saved.useLedger.papers.count == 1)
        #expect(store.currentHistoryID == old.id)
        #expect(!store.isRefreshingHistory)
    }

    @Test func delayedFirstUsableReturnPreservesNewerVisibleUse() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            firstUsableReturnDelay: .milliseconds(200)
        )
        try await historyStore.bootstrap()
        let oldWork = makeWork()
        let old = makeRecord(query: "gut", works: [oldWork], date: Date(timeIntervalSince1970: 1))
        _ = try await historyStore.save(old)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)
        let generation = await store.beginHistorySearch(displayQuery: "gut")
        let newWork = makeWork(
            id: "https://openalex.org/W2",
            doi: "10.1000/new"
        )
        var staged = old
        staged.snapshot.allWorks = [newWork]
        staged.snapshot.rankedWorks = [newWork]
        staged.snapshot.totalCount = 1
        staged.snapshot.selectedWorkID = newWork.id
        store.restoreHistoryRecord(staged)
        let pendingFirstStage = Task { @MainActor in
            await store.commitFirstUsableHistoryStage(
                displayQuery: "gut",
                startedAt: Date(timeIntervalSince1970: 10),
                generation: generation
            )
        }
        while await !historyStore.isFirstUsableReturnDelayed {
            await Task.yield()
        }

        await store.setUse(true, for: oldWork)
        await pendingFirstStage.value

        let disk = try await historyStore.loadRecord(id: old.id)
        #expect(disk.snapshot.revision == 1)
        #expect(disk.snapshot.allWorks.map(\.shortID) == ["W2"])
        #expect(disk.useLedger.contains(oldWork))
        #expect(store.currentHistoryRecord?.snapshot.allWorks.map(\.shortID) == ["W2"])
        #expect(store.currentHistoryRecord?.useLedger.contains(oldWork) == true)
        #expect(store.decision(for: oldWork) == .use)
        #expect(store.historySummaries.first(where: { $0.id == old.id })?.useCount == 1)
    }

    @Test func delayedUseIndexDoesNotRegressRefreshSummaryMetadata() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            indexReturnDelay: .milliseconds(200)
        )
        try await historyStore.bootstrap()
        let oldWork = makeWork()
        let old = makeRecord(query: "gut", works: [oldWork], date: Date(timeIntervalSince1970: 1))
        _ = try await historyStore.save(old)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)
        let generation = await store.beginHistorySearch(displayQuery: "gut")
        let newWorks = [
            makeWork(id: "https://openalex.org/W2", doi: "10.1000/new-1"),
            makeWork(id: "https://openalex.org/W3", doi: "10.1000/new-2")
        ]
        var staged = old
        staged.snapshot.allWorks = newWorks
        staged.snapshot.rankedWorks = newWorks
        staged.snapshot.totalCount = newWorks.count
        staged.snapshot.selectedWorkID = newWorks.first?.id
        store.restoreHistoryRecord(staged)
        let pendingUse = Task { @MainActor in
            await store.setUse(true, for: oldWork)
        }
        while await !historyStore.isIndexReturnDelayed {
            await Task.yield()
        }

        await store.commitFirstUsableHistoryStage(
            displayQuery: "gut",
            startedAt: Date(timeIntervalSince1970: 10),
            generation: generation
        )
        await pendingUse.value

        let disk = try await historyStore.loadRecord(id: old.id)
        let summary = store.historySummaries.first { $0.id == old.id }
        #expect(disk.snapshot.rankedWorks.count == 2)
        #expect(disk.useLedger.contains(oldWork))
        #expect(summary?.paperCount == 2)
        #expect(summary?.lastSuccessfulSearchAt == disk.lastSuccessfulSearchAt)
        #expect(summary?.displayQuery == disk.displayQuery)
        #expect(summary?.useCount == 1)
    }

    @Test func failedFirstUsableCommitRestoresOldMatchingRecord() async throws {
        let root = try makeTemporaryDirectory()
        let historyRoot = root.appendingPathComponent("SearchHistory")
        let historyStore = SearchHistoryStore(
            root: historyRoot,
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        let old = makeRecord(query: "gut", works: [makeWork()], date: Date())
        try await historyStore.bootstrap()
        _ = try await historyStore.save(old)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)
        let generation = await store.beginHistorySearch(displayQuery: "gut")
        let newWork = makeWork(id: "https://openalex.org/W2")
        var staged = old
        staged.snapshot.allWorks = [newWork]
        staged.snapshot.rankedWorks = [newWork]
        staged.snapshot.totalCount = 1
        staged.snapshot.selectedWorkID = newWork.id
        store.restoreHistoryRecord(staged)
        try setHistoryPermissions(0o500, at: historyRoot)

        await store.commitFirstUsableHistoryStage(
            displayQuery: "gut",
            startedAt: Date(),
            generation: generation
        )
        try setHistoryPermissions(0o700, at: historyRoot)

        let onDisk = try await historyStore.loadRecord(id: old.id)
        #expect(onDisk == old)
        #expect(store.currentHistoryID == old.id)
        #expect(store.works == old.snapshot.allWorks)
        #expect(store.historyErrorMessage == "Search completed, but history could not be saved.")
        #expect(!store.isRefreshingHistory)
    }

    @Test func concurrentUseDuringFirstCommitIsMergedIntoReplacement() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            persistenceDelay: .milliseconds(200)
        )
        try await historyStore.bootstrap()
        let oldWork = makeWork()
        let old = makeRecord(query: "gut", works: [oldWork], date: Date())
        _ = try await historyStore.save(old)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)
        let generation = await store.beginHistorySearch(displayQuery: "gut")
        let newWork = makeWork(id: "https://openalex.org/W2")
        var staged = old
        staged.snapshot.allWorks = [newWork]
        staged.snapshot.rankedWorks = [newWork]
        staged.snapshot.totalCount = 1
        staged.snapshot.selectedWorkID = newWork.id
        store.restoreHistoryRecord(staged)
        let pending = Task { @MainActor in
            await store.commitFirstUsableHistoryStage(
                displayQuery: "gut",
                startedAt: Date(),
                generation: generation
            )
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(25))

        _ = try await historyStore.setUse(historyID: old.id, work: oldWork, isUsed: true)
        await pending.value

        let saved = try await historyStore.loadRecord(id: old.id)
        #expect(saved.snapshot.allWorks.map(\.shortID) == ["W2"])
        #expect(saved.useLedger.contains(oldWork))
    }

    @Test func failedFirstCommitReloadsConcurrentUseFromRollback() async throws {
        let root = try makeTemporaryDirectory()
        let historyRoot = root.appendingPathComponent("SearchHistory")
        let historyStore = SearchHistoryStore(
            root: historyRoot,
            legacyRoot: root.appendingPathComponent("SearchSession"),
            persistenceDelay: .milliseconds(200)
        )
        try await historyStore.bootstrap()
        let oldWork = makeWork()
        let old = makeRecord(query: "gut", works: [oldWork], date: Date())
        _ = try await historyStore.save(old)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)
        let generation = await store.beginHistorySearch(displayQuery: "gut")
        let newWork = makeWork(id: "https://openalex.org/W2")
        var staged = old
        staged.snapshot.allWorks = [newWork]
        staged.snapshot.rankedWorks = [newWork]
        staged.snapshot.totalCount = 1
        staged.snapshot.selectedWorkID = newWork.id
        store.restoreHistoryRecord(staged)
        let pending = Task { @MainActor in
            await store.commitFirstUsableHistoryStage(
                displayQuery: "gut",
                startedAt: Date(),
                generation: generation
            )
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(25))

        _ = try await historyStore.setUse(
            historyID: old.id,
            work: oldWork,
            isUsed: true
        )
        try setHistoryPermissions(0o500, at: historyRoot)
        await pending.value
        try setHistoryPermissions(0o700, at: historyRoot)

        let onDisk = try await historyStore.loadRecord(id: old.id)
        #expect(onDisk.snapshot.allWorks.map(\.shortID) == ["W1"])
        #expect(onDisk.useLedger.contains(oldWork))
        #expect(store.currentHistoryRecord?.useLedger.contains(oldWork) == true)
        #expect(store.decision(for: oldWork) == .use)
        #expect(store.historyErrorMessage == "Search completed, but history could not be saved.")
    }

    @Test func staleGenerationCannotCommitFirstUsableStage() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            persistenceDelay: .milliseconds(200)
        )
        try await historyStore.bootstrap()
        let first = makeRecord(query: "first", works: [makeWork()], date: Date())
        let second = makeRecord(
            query: "second",
            works: [makeWork(id: "https://openalex.org/W2")],
            date: Date().addingTimeInterval(1)
        )
        _ = try await historyStore.save(first)
        _ = try await historyStore.save(second)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(first.id)
        let stale = await store.beginHistorySearch(displayQuery: "first")
        let replacement = makeWork(id: "https://openalex.org/W3")
        var staged = first
        staged.snapshot.allWorks = [replacement]
        staged.snapshot.rankedWorks = [replacement]
        staged.snapshot.totalCount = 1
        staged.snapshot.selectedWorkID = replacement.id
        store.restoreHistoryRecord(staged)
        let pending = Task { @MainActor in
            await store.commitFirstUsableHistoryStage(
                displayQuery: "first",
                startedAt: Date(),
                generation: stale
            )
        }
        await Task.yield()
        try await Task.sleep(for: .milliseconds(25))

        _ = await store.beginHistorySearch(displayQuery: "second")

        await pending.value

        #expect(try await historyStore.loadRecord(id: first.id).snapshot.revision == 0)
        #expect(try await historyStore.loadRecord(id: first.id).snapshot.allWorks.map(\.shortID) == ["W1"])
        #expect(try await historyStore.loadRecord(id: second.id).snapshot.revision == 0)
    }

    @Test func usedPaperAbsentFromAllRemainsInUse() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let used = makeWork(id: "https://openalex.org/W1")
        let current = makeWork(
            id: "https://openalex.org/W2",
            doi: "10.1000/current"
        )
        var ledger = UseLedger()
        ledger.mark(used, at: Date(timeIntervalSince1970: 1))
        let record = makeRecord(
            query: "gut",
            works: [current],
            date: Date(),
            useLedger: ledger
        )
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(record.id)

        #expect(store.filteredWorks.map(\.shortID) == ["W2"])
        store.decisionFilter = .use

        #expect(store.filteredWorks.map(\.shortID) == ["W1"])
        #expect(store.decision(for: used) == .use)
        #expect(store.hasMarkedUseWorks)
    }

    @Test func stableIdentityReappearanceIsRecognizedAsUse() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let used = makeWork(id: "old-local-id", pmid: nil, year: nil)
        let reappeared = makeWork(id: "new-local-id", pmid: nil, year: nil)
        var ledger = UseLedger()
        ledger.mark(used)
        let record = makeRecord(
            query: "gut",
            works: [reappeared],
            date: Date(),
            useLedger: ledger
        )
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(record.id)

        #expect(store.decision(for: reappeared) == .use)
    }

    @Test func successfulUseTogglePersistsAndUpdatesVisibleHistory() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let work = makeWork()
        let record = makeRecord(query: "gut", works: [work], date: Date())
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(record.id)

        await store.setUse(true, for: work)

        #expect(store.decision(for: work) == .use)
        #expect(store.currentHistoryRecord?.useLedger.contains(work) == true)
        #expect(store.historySummaries.first?.useCount == 1)
        #expect(try await historyStore.loadRecord(id: record.id).useLedger.contains(work))
    }

    @Test func concurrentStageAndUsePublishNewestSnapshotAndLedger() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            useReturnDelay: .milliseconds(200)
        )
        try await historyStore.bootstrap()
        let work = makeWork()
        let record = makeRecord(query: "gut", works: [work], date: Date())
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(record.id)
        let generation = store.captureHistoryMutationContext().searchGeneration
        var snapshot = store.makeHistorySnapshot(displayQuery: "gut", revision: 1)
        snapshot.searchTimingSummary = "newest stage"
        let pendingUse = Task { @MainActor in
            await store.setUse(true, for: work)
        }
        while await !historyStore.isUseReturnDelayed {
            await Task.yield()
        }

        await store.persistCurrentStage(snapshot, expectedGeneration: generation)
        await pendingUse.value

        let disk = try await historyStore.loadRecord(id: record.id)
        #expect(disk.snapshot.revision == 1)
        #expect(disk.snapshot.searchTimingSummary == "newest stage")
        #expect(disk.useLedger.contains(work))
        #expect(store.currentHistoryRecord?.snapshot.revision == 1)
        #expect(store.currentHistoryRecord?.snapshot.searchTimingSummary == "newest stage")
        #expect(store.currentHistoryRecord?.useLedger.contains(work) == true)
    }

    @Test func failedUseWriteRestoresPreviousVisibleDecision() async throws {
        let root = try makeTemporaryDirectory()
        let historyRoot = root.appendingPathComponent("SearchHistory")
        let historyStore = SearchHistoryStore(
            root: historyRoot,
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let work = makeWork()
        let record = makeRecord(query: "gut", works: [work], date: Date())
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(record.id)
        try setHistoryPermissions(0o500, at: historyRoot)
        defer { try? setHistoryPermissions(0o700, at: historyRoot) }

        await store.setUse(true, for: work)

        #expect(store.decision(for: work) == .unreviewed)
        #expect(store.currentHistoryRecord == record)
        #expect(
            store.historyErrorMessage
                == "Use could not be saved. Your previous selection was restored."
        )
    }

    @Test func rapidDecisionTogglesPersistTheLatestSelection() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let work = makeWork()
        let record = makeRecord(query: "gut", works: [work], date: Date())
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(record.id)

        store.setScanDecision(.use, for: work)
        store.setScanDecision(.unreviewed, for: work)
        await store.waitForPendingUseMutations()

        #expect(store.decision(for: work) == .unreviewed)
        #expect(store.currentHistoryRecord?.useLedger.contains(work) == false)
        #expect(store.historySummaries.first?.useCount == 0)
        #expect(try await historyStore.loadRecord(id: record.id).useLedger.contains(work) == false)
    }

    @Test func pendingUseAcrossHistorySwitchNeverPublishesIntoNewHistory() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            useReturnDelay: .milliseconds(200)
        )
        try await historyStore.bootstrap()
        let oldWork = makeWork()
        let old = makeRecord(query: "old", works: [oldWork], date: Date())
        let newWork = makeWork(
            id: "https://openalex.org/W2",
            doi: "10.1000/new"
        )
        let new = makeRecord(
            query: "new",
            works: [newWork],
            date: Date().addingTimeInterval(1)
        )
        _ = try await historyStore.save(old)
        _ = try await historyStore.save(new)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)
        store.setScanDecision(.use, for: oldWork)
        while await !historyStore.isUseReturnDelayed {
            await Task.yield()
        }

        await store.openHistory(new.id)
        await store.waitForPendingUseMutations()

        #expect(store.currentHistoryID == new.id)
        #expect(store.currentHistoryRecord == new)
        #expect(store.historyErrorMessage == nil)
        #expect(try await historyStore.loadRecord(id: old.id).useLedger.contains(oldWork))
        #expect(try await historyStore.loadRecord(id: new.id).useLedger.papers.isEmpty)
    }
}

private func setHistoryPermissions(_ permissions: Int, at url: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: permissions)],
        ofItemAtPath: url.path
    )
}
