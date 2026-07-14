import AppKit
import Foundation
import SwiftUI
import Testing
@testable import RagBio

@MainActor
@Suite struct SearchStoreHistoryTests {
    @Test func mountingRestoredSelectionDoesNotStartNetworkOrSummaryWork() async throws {
        let root = try makeTemporaryDirectory()
        let historyRoot = root.appendingPathComponent("SearchHistory")
        let work = makeWork(
            id: "https://openalex.org/W\(UUID().uuidString)",
            doi: "10.1000/restore-\(UUID().uuidString)"
        )
        let record = makeRecord(query: "restored", works: [work], date: Date())
        let historyStore = SearchHistoryStore(
            root: historyRoot,
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        _ = try await historyStore.save(record)

        RecordingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let store = SearchStore(
            client: OpenAlexClient(session: session),
            fullTextService: FullTextService(session: session),
            aiQueryPlanner: AIQueryPlanner(session: session),
            historyStore: historyStore,
            restoreOnInit: false
        )
        await store.openHistory(record.id)

        let hostingView = NSHostingView(rootView: ContentView(store: store))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1_100, height: 760)
        hostingView.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))

        #expect(RecordingURLProtocol.requestCount == 0)
        #expect(store.fullTextState == .idle)
        #expect(store.articleSummaryInProgress.isEmpty)
        #expect(store.aiVisiblePageFullTextInProgress.isEmpty)
        withExtendedLifetime(hostingView) {}
    }

    @Test func useProjectionKeepsLedgerOrderAndPrefersRefreshedStableIdentityMetadata() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let old = makeWork(
            id: "old-selection-id",
            doi: "10.1000/stable",
            pmid: nil,
            title: "Old title",
            publisherURL: "https://old.example/paper"
        )
        let missing = makeWork(
            id: "ledger-only-id",
            doi: "10.1000/missing",
            pmid: nil,
            title: "Ledger only"
        )
        let refreshed = makeWork(
            id: "refreshed-id",
            doi: "10.1000/stable",
            pmid: nil,
            title: "Refreshed title",
            publisherURL: "https://new.example/paper"
        )
        let current = makeWork(
            id: "current-id",
            doi: "10.1000/current",
            pmid: nil,
            title: "Current unrelated"
        )
        var ledger = UseLedger()
        ledger.mark(old, at: Date(timeIntervalSince1970: 1))
        ledger.mark(missing, at: Date(timeIntervalSince1970: 2))
        var record = makeRecord(
            query: "gut",
            works: [current],
            date: Date(),
            useLedger: ledger
        )
        record.snapshot.rankedWorks = [refreshed, current]
        record.snapshot.selectedWorkID = old.id
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)

        await store.openHistory(record.id)
        store.decisionFilter = .use

        #expect(store.useWorks.map(\.id) == [refreshed.id, missing.id])
        #expect(store.useWorks.map(\.title) == ["Refreshed title", "Ledger only"])
        #expect(store.filteredWorks.map(\.id) == [refreshed.id, missing.id])
        #expect(store.selectedWork?.id == refreshed.id)
        #expect(store.workTitleLookup[refreshed.id] == "Refreshed title")
        #expect(store.workTitleLookup[missing.id] == "Ledger only")
        #expect(store.workURLLookup[refreshed.id]?.absoluteString == "https://new.example/paper")
        store.generateEvidenceTable()
        #expect(store.currentEvidenceTable?.basedOnWorkIDs == [refreshed.id, missing.id])
    }

    @Test func useProjectionDrivesEvidenceTableAndMarkedFieldSummarySources() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let visible = makeWork(id: "visible", doi: "10.1000/visible")
        let ledgerOnly = makeWork(id: "ledger-only", doi: "10.1000/ledger")
        var ledger = UseLedger()
        ledger.mark(ledgerOnly)
        let record = makeRecord(
            query: "gut",
            works: [visible],
            date: Date(),
            useLedger: ledger
        )
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(record.id)

        #expect(store.decisionFilter == .all)
        store.generateEvidenceTable()

        #expect(store.currentEvidenceTable?.basedOnWorkIDs == [ledgerOnly.id])
        #expect(store.currentEvidenceTable?.rows.map(\.title) == [ledgerOnly.title])
        #expect(store.fieldSummarySourceWorks(scope: .marked).map(\.id) == [ledgerOnly.id])
        let table = try #require(store.currentEvidenceTable)
        #expect(FieldScanService().selectedRows(from: table).map(\.workID) == [ledgerOnly.id])
    }

    @Test func bridgedUseProjectionIsOneRowAndOldSelectionOpensRefreshedDetail() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let doiOnly = makeWork(
            id: "doi-only",
            doi: "10.1000/bridge",
            pmid: nil,
            title: "DOI source"
        )
        let pmidOnly = makeWork(
            id: "pmid-only",
            doi: nil,
            pmid: "https://pubmed.ncbi.nlm.nih.gov/987/",
            title: "PMID source"
        )
        let bridge = makeWork(
            id: "bridge",
            doi: "10.1000/bridge",
            pmid: "https://pubmed.ncbi.nlm.nih.gov/987/",
            title: "Refreshed bridge"
        )
        var ledger = UseLedger()
        ledger.mark(doiOnly, at: Date(timeIntervalSince1970: 1))
        ledger.mark(pmidOnly, at: Date(timeIntervalSince1970: 2))
        var record = makeRecord(query: "bridge", works: [bridge], date: Date(), useLedger: ledger)
        record.snapshot.selectedWorkID = pmidOnly.id
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)

        await store.openHistory(record.id)
        store.generateEvidenceTable()

        #expect(store.useWorks.map(\.id) == [bridge.id])
        #expect(store.selectedWork?.id == bridge.id)
        #expect(store.selectedWork?.title == "Refreshed bridge")
        #expect(store.currentEvidenceTable?.basedOnWorkIDs == [bridge.id])
        #expect(Set(store.currentEvidenceTable?.basedOnWorkIDs ?? []).count == 1)
    }

    @Test func replacementSearchInvalidatesDelayedFirstStageBeforeItCanPublish() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            persistenceDelay: .seconds(2)
        )
        try await historyStore.bootstrap()
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        let firstGeneration = await store.beginHistorySearch(displayQuery: "first")
        let firstWork = makeWork(id: "first", doi: "10.1000/first")
        store.restoreHistoryRecord(makeRecord(query: "first", works: [firstWork], date: Date()))
        let pending = Task { @MainActor in
            await store.commitFirstUsableHistoryStage(
                displayQuery: "first",
                startedAt: Date(),
                generation: firstGeneration
            )
        }
        while await !historyStore.isPersistenceDelayed { await Task.yield() }

        _ = await store.beginHistorySearch(displayQuery: "second")
        await pending.value

        #expect(store.query == "second")
        #expect(store.currentHistoryID == nil)
        let index = try await historyStore.loadIndex()
        #expect(!index.summaries.contains { $0.normalizedQuery == "first" })
    }

    @Test func historiesRestoreIndependentDecisionFiltersAcrossOpenAndRestart() async throws {
        let root = try makeTemporaryDirectory()
        let historyRoot = root.appendingPathComponent("SearchHistory")
        let historyStore = SearchHistoryStore(
            root: historyRoot,
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        var useRecord = makeRecord(
            query: "use history",
            works: [makeWork()],
            date: Date(timeIntervalSince1970: 1)
        )
        useRecord.snapshot.decisionFilter = .use
        var allRecord = makeRecord(
            query: "all history",
            works: [makeWork(id: "W2", doi: "10.1000/two")],
            date: Date(timeIntervalSince1970: 2)
        )
        allRecord.snapshot.decisionFilter = .all
        _ = try await historyStore.save(useRecord)
        _ = try await historyStore.save(allRecord)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)

        await store.openHistory(useRecord.id)
        #expect(store.decisionFilter == .use)
        await store.openHistory(allRecord.id)
        #expect(store.decisionFilter == .all)
        await store.openHistory(useRecord.id)
        #expect(store.decisionFilter == .use)

        let restarted = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await restarted.loadInitialHistory()
        #expect(restarted.currentHistoryID == useRecord.id)
        #expect(restarted.decisionFilter == .use)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await historyStore.loadRecord(id: useRecord.id).snapshot.revision == 0)
        #expect(try await historyStore.loadRecord(id: allRecord.id).snapshot.revision == 0)
    }

    @Test func restoreUsesConservativePersistedAIStage() {
        let work = makeWork()
        let cases: [(SearchHistoryAIStage?, AIRerankState, AISecondRerankState)] = [
            (nil, .localReady(candidates: 1), .idle),
            (.localCandidates, .localReady(candidates: 1), .idle),
            (.coarseRanking, .completed(candidates: 1, retained: 1), .idle),
            (
                .evidenceRanking,
                .completed(candidates: 1, retained: 1),
                .completed(fullText: 1, abstractOnly: 0, retained: 1)
            )
        ]
        for (stage, coarse, evidence) in cases {
            var record = makeRecord(query: "stage", works: [work], date: Date())
            record.snapshot.completedAIStage = stage
            record.snapshot.aiEvidenceLevels = [work.id: "全文段落精排"]
            let store = SearchStore(restoreOnInit: false)

            store.restoreHistoryRecord(record)

            #expect(store.aiRerankState == coarse)
            #expect(store.aiSecondRerankState == evidence)
            #expect(
                store.makeHistorySnapshot(displayQuery: "stage", revision: 1).completedAIStage
                    == (stage ?? .localCandidates)
            )
        }
    }
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

    @Test func openingAnotherHistoryInvalidatesAllAsyncMutationGenerationsAndLaterStage() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            persistenceDelay: .seconds(2)
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
        var staleSnapshot = first.snapshot
        staleSnapshot.revision = 1
        staleSnapshot.searchTimingSummary = "stale later stage"
        let pending = Task { @MainActor in
            await store.persistCurrentStage(
                staleSnapshot,
                expectedGeneration: firstContext.searchGeneration
            )
        }
        while await !historyStore.isPersistenceDelayed { await Task.yield() }

        await store.openHistory(second.id)
        await pending.value
        let secondContext = store.captureHistoryMutationContext()

        #expect(firstContext.searchGeneration != secondContext.searchGeneration)
        #expect(firstContext.corpusGeneration != secondContext.corpusGeneration)
        #expect(!store.isCurrentHistoryMutationContext(firstContext))
        #expect(try await historyStore.loadRecord(id: first.id).snapshot.revision == 0)
        #expect(store.currentHistoryID == second.id)
        #expect(store.works.map(\.shortID) == ["W2"])
        #expect(store.currentHistoryRecord == second)
    }

    @Test func openingAnotherHistoryPreventsPendingFirstStagePersistenceAndPublication() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            persistenceDelay: .seconds(2)
        )
        try await historyStore.bootstrap()
        let saved = makeRecord(query: "saved", works: [makeWork()], date: Date())
        _ = try await historyStore.save(saved)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        let generation = await store.beginHistorySearch(displayQuery: "new query")
        let stagedWork = makeWork(
            id: "https://openalex.org/W2",
            doi: "10.1000/staged"
        )
        store.restoreHistoryRecord(
            makeRecord(query: "new query", works: [stagedWork], date: Date())
        )
        let pending = Task { @MainActor in
            await store.commitFirstUsableHistoryStage(
                displayQuery: "new query",
                startedAt: Date(),
                generation: generation
            )
        }
        while await !historyStore.isPersistenceDelayed { await Task.yield() }

        await store.openHistory(saved.id)
        await pending.value

        let index = try await historyStore.loadIndex()
        #expect(index.summaries.map(\.id) == [saved.id])
        #expect(store.currentHistoryID == saved.id)
        #expect(store.currentHistoryRecord == saved)
        #expect(store.works.map(\.shortID) == ["W1"])
    }

    @Test func openingDamagedHistoryClearsVisibleStateAndValidHistoryStillOpens() async throws {
        let root = try makeTemporaryDirectory()
        let historyRoot = root.appendingPathComponent("SearchHistory")
        let historyStore = SearchHistoryStore(
            root: historyRoot,
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let valid = makeRecord(query: "valid", works: [makeWork()], date: Date())
        let damaged = makeRecord(
            query: "damaged",
            works: [makeWork(id: "https://openalex.org/W2")],
            date: Date().addingTimeInterval(1)
        )
        _ = try await historyStore.save(valid)
        _ = try await historyStore.save(damaged)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(valid.id)
        try Data("broken".utf8).write(
            to: historyRoot.appendingPathComponent("records/\(damaged.id.uuidString).json")
        )

        await store.openHistory(damaged.id)

        #expect(store.historyErrorMessage == "This search history is damaged and could not be opened.")
        #expect(store.currentHistoryID == nil)
        #expect(store.currentHistoryRecord == nil)
        #expect(store.query.isEmpty)
        #expect(store.works.isEmpty)
        #expect(!store.historySummaries.contains { $0.id == damaged.id })
        #expect(store.historySummaries.map(\.id) == [valid.id])

        await store.openHistory(valid.id)

        #expect(store.historyErrorMessage == nil)
        #expect(store.currentHistoryID == valid.id)
        #expect(store.works.map(\.shortID) == ["W1"])
    }

    @Test func indexMetadataFailureKeepsSuccessfullyRestoredHistoryVisible() async throws {
        let root = try makeTemporaryDirectory()
        let historyRoot = root.appendingPathComponent("SearchHistory")
        let historyStore = SearchHistoryStore(
            root: historyRoot,
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let used = makeWork()
        var ledger = UseLedger()
        ledger.mark(used)
        var record = makeRecord(
            query: "metadata failure",
            works: [used],
            date: Date(),
            useLedger: ledger
        )
        record.snapshot.sort = .newest
        record.snapshot.fromYearEnabled = true
        record.snapshot.fromYear = 2018
        record.snapshot.openAccessOnly = true
        _ = try await historyStore.save(record)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        try setHistoryPermissions(0o500, at: historyRoot)
        defer { try? setHistoryPermissions(0o700, at: historyRoot) }

        await store.openHistory(record.id)

        #expect(store.historyErrorMessage != nil)
        #expect(store.currentHistoryID == record.id)
        #expect(store.currentHistoryRecord == record)
        #expect(store.query == "metadata failure")
        #expect(store.works.map(\.shortID) == ["W1"])
        #expect(store.sort == .newest)
        #expect(store.fromYearEnabled)
        #expect(store.fromYear == 2018)
        #expect(store.openAccessOnly)
        #expect(store.decision(for: used) == .use)
        #expect(store.historySummaries.map(\.id) == [record.id])
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
        await store.setUse(true, for: old.snapshot.allWorks[0])
        store.sort = .newest
        store.fromYearEnabled = true
        store.fromYear = 2017
        store.openAccessOnly = true

        let generation = await store.beginHistorySearch(displayQuery: " GUT ")

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
        var staged = try #require(store.currentHistoryRecord)
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
            displayQuery: " GUT ",
            startedAt: Date(timeIntervalSince1970: 10),
            generation: generation
        )

        let saved = try await historyStore.loadRecord(id: old.id)
        let index = try await historyStore.loadIndex()
        #expect(index.summaries.count == 1)
        #expect(index.summaries.first?.id == old.id)
        #expect(index.summaries.first?.normalizedQuery == SearchQueryIdentity.normalize("gut"))
        #expect(index.summaries.first?.useCount == 1)
        #expect(saved.snapshot.allWorks.map(\.shortID) == ["W2"])
        #expect(saved.snapshot.sort == .newest)
        #expect(saved.snapshot.fromYearEnabled)
        #expect(saved.snapshot.fromYear == 2017)
        #expect(saved.snapshot.openAccessOnly)
        #expect(saved.useLedger.papers.count == 1)
    }

    @Test func zeroResultFirstCommitDoesNotCreateHistory() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        let generation = await store.beginHistorySearch(displayQuery: "no results")

        await store.commitFirstUsableHistoryStage(
            displayQuery: "no results",
            startedAt: Date(),
            generation: generation
        )

        #expect(try await historyStore.loadIndex().summaries.isEmpty)
        #expect(store.currentHistoryID == nil)
        #expect(store.currentHistoryRecord == nil)
    }

    @Test func restartRestoresLastCompletedStageFiltersAndUseWithoutLoading() async throws {
        let root = try makeTemporaryDirectory()
        let historyRoot = root.appendingPathComponent("SearchHistory")
        let legacyRoot = root.appendingPathComponent("SearchSession")
        let writer = SearchHistoryStore(root: historyRoot, legacyRoot: legacyRoot)
        try await writer.bootstrap()
        let used = makeWork()
        let visible = makeWork(
            id: "https://openalex.org/W2",
            doi: "10.1000/visible"
        )
        var ledger = UseLedger()
        ledger.mark(used, at: Date(timeIntervalSince1970: 1))
        var record = makeRecord(
            query: "restart query",
            works: [visible],
            date: Date(timeIntervalSince1970: 2),
            useLedger: ledger
        )
        record.snapshot.revision = 4
        record.snapshot.sort = .newest
        record.snapshot.fromYearEnabled = true
        record.snapshot.fromYear = 2019
        record.snapshot.openAccessOnly = true
        record.snapshot.searchTimingSummary = "completed stage"
        _ = try await writer.save(record)

        RecordingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let reader = SearchHistoryStore(root: historyRoot, legacyRoot: legacyRoot)
        let relaunched = SearchStore(
            client: OpenAlexClient(session: session),
            fullTextService: FullTextService(session: session),
            aiQueryPlanner: AIQueryPlanner(session: session),
            historyStore: reader,
            restoreOnInit: false
        )
        await relaunched.loadInitialHistory()

        #expect(relaunched.currentHistoryID == record.id)
        #expect(relaunched.query == "restart query")
        #expect(relaunched.works.map(\.shortID) == ["W2"])
        #expect(relaunched.sort == .newest)
        #expect(relaunched.fromYearEnabled)
        #expect(relaunched.fromYear == 2019)
        #expect(relaunched.openAccessOnly)
        #expect(relaunched.currentHistoryRecord?.snapshot.revision == 4)
        #expect(relaunched.searchTimingSummary == "completed stage")
        #expect(relaunched.currentHistoryRecord?.useLedger.contains(used) == true)
        #expect(!relaunched.isLoading)
        #expect(!relaunched.isRefreshingHistory)
        #expect(relaunched.aiRerankState == .localReady(candidates: 1))
        #expect(relaunched.aiSecondRerankState == .idle)
        #expect(RecordingURLProtocol.requestCount == 0)
    }

    @Test func staleGenerationCannotPersistStage() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            persistenceDelay: .seconds(2)
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
        while await !historyStore.isPersistenceDelayed { await Task.yield() }

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

    @Test func firstUsableCommitPublishesTheActorsReconciledBridgeLedgerEverywhere() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let doiOnly = makeWork(
            id: "doi-only",
            doi: "10.1000/bridge",
            pmid: nil,
            title: "DOI source"
        )
        let pmidOnly = makeWork(
            id: "pmid-only",
            doi: nil,
            pmid: "https://pubmed.ncbi.nlm.nih.gov/987/",
            title: "PMID source"
        )
        let bridge = makeWork(
            id: "bridge",
            doi: "10.1000/bridge",
            pmid: "https://pubmed.ncbi.nlm.nih.gov/987/",
            title: "Refreshed bridge"
        )
        var ledger = UseLedger()
        ledger.mark(doiOnly, at: Date(timeIntervalSince1970: 1))
        ledger.mark(pmidOnly, at: Date(timeIntervalSince1970: 2))
        let old = makeRecord(
            query: "bridge",
            works: [doiOnly],
            date: Date(timeIntervalSince1970: 1),
            useLedger: ledger
        )
        _ = try await historyStore.save(old)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)
        let generation = await store.beginHistorySearch(displayQuery: "bridge")
        var staged = old
        staged.snapshot = makeSnapshot(query: "bridge", works: [bridge])
        store.restoreHistoryRecord(staged)

        await store.commitFirstUsableHistoryStage(
            displayQuery: "bridge",
            startedAt: Date(timeIntervalSince1970: 10),
            generation: generation
        )

        #expect(store.currentHistoryRecord?.useLedger.papers.count == 1)
        #expect(store.currentHistoryRecord?.useLedger.papers.first?.work.id == bridge.id)
        #expect(store.useWorks.map(\.id) == [bridge.id])
        #expect(store.scanDecisions.keys.sorted() == [bridge.id])
        #expect(store.historySummaries.first(where: { $0.id == old.id })?.useCount == 1)
        let disk = try await historyStore.loadRecord(id: old.id)
        #expect(disk.useLedger.papers.count == 1)
        let export = SearchHistoryExportBuilder.make(records: [disk])
        #expect(export.urlCount == 1)
        #expect(export.text.components(separatedBy: "https://doi.org/10.1000/bridge").count - 1 == 1)
    }

    @Test func bridgeReconciliationPreservesAConcurrentNewUseDuringFirstStageReturn() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession"),
            firstUsableReturnDelay: .seconds(2)
        )
        try await historyStore.bootstrap()
        let doiOnly = makeWork(id: "doi-only", doi: "10.1000/bridge", pmid: nil, title: "DOI")
        let pmidOnly = makeWork(
            id: "pmid-only",
            doi: nil,
            pmid: "https://pubmed.ncbi.nlm.nih.gov/987/",
            title: "PMID"
        )
        let bridge = makeWork(
            id: "bridge",
            doi: "10.1000/bridge",
            pmid: "https://pubmed.ncbi.nlm.nih.gov/987/",
            title: "Bridge"
        )
        let concurrent = makeWork(
            id: "concurrent",
            doi: "10.1000/concurrent",
            pmid: nil,
            title: "Concurrent"
        )
        var ledger = UseLedger()
        ledger.mark(doiOnly)
        ledger.mark(pmidOnly)
        let old = makeRecord(query: "bridge", works: [doiOnly], date: Date(), useLedger: ledger)
        _ = try await historyStore.save(old)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)
        let generation = await store.beginHistorySearch(displayQuery: "bridge")
        var staged = old
        staged.snapshot = makeSnapshot(query: "bridge", works: [bridge])
        store.restoreHistoryRecord(staged)
        let pending = Task { @MainActor in
            await store.commitFirstUsableHistoryStage(
                displayQuery: "bridge",
                startedAt: Date(),
                generation: generation
            )
        }
        while await !historyStore.isFirstUsableReturnDelayed { await Task.yield() }

        await store.setUse(true, for: concurrent)
        await pending.value

        #expect(store.currentHistoryRecord?.useLedger.papers.map(\.work.id) == [bridge.id, concurrent.id])
        #expect(store.useWorks.map(\.id) == [bridge.id, concurrent.id])
        #expect(store.scanDecisions.count == 2)
        #expect(store.historySummaries.first(where: { $0.id == old.id })?.useCount == 2)
        let disk = try await historyStore.loadRecord(id: old.id)
        #expect(disk.useLedger.papers.map(\.work.id) == [bridge.id, concurrent.id])
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
            persistenceDelay: .seconds(2)
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
        while await !historyStore.isPersistenceDelayed { await Task.yield() }

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
            persistenceDelay: .seconds(2)
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
        while await !historyStore.isPersistenceDelayed { await Task.yield() }

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
            persistenceDelay: .seconds(2)
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
        while await !historyStore.isPersistenceDelayed { await Task.yield() }

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

private final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedRequestCount = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestCount
    }

    static func reset() {
        lock.lock()
        storedRequestCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        Self.storedRequestCount += 1
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
