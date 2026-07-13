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

    @Test func staleGenerationCannotPersistStage() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        let stale = await store.beginHistorySearch(displayQuery: "first")
        let snapshot = store.makeHistorySnapshot(displayQuery: "first", revision: 1)
        _ = await store.beginHistorySearch(displayQuery: "second")

        await store.persistCurrentStage(snapshot, expectedGeneration: stale)

        let index = try await historyStore.loadIndex()
        #expect(index.summaries.isEmpty)
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
        let old = makeRecord(query: "old", works: [makeWork()], date: Date())
        _ = try await historyStore.save(old)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        await store.openHistory(old.id)

        _ = await store.beginHistorySearch(displayQuery: "new")

        #expect(store.currentHistoryID == nil)
        #expect(store.works.isEmpty)
        #expect(store.evidence.isEmpty)
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

        await store.commitFirstUsableHistoryStage(
            displayQuery: "gut microbiota",
            startedAt: Date(timeIntervalSince1970: 10),
            generation: generation
        )

        let saved = try await historyStore.loadRecord(id: old.id)
        #expect(saved.id == old.id)
        #expect(saved.createdAt == old.createdAt)
        #expect(saved.snapshot.revision == 5)
        #expect(saved.useLedger.papers.count == 1)
        #expect(store.currentHistoryID == old.id)
        #expect(!store.isRefreshingHistory)
    }

    @Test func failedFirstUsableCommitRestoresOldMatchingRecord() async throws {
        let root = try makeTemporaryDirectory()
        let blockedRoot = root.appendingPathComponent("SearchHistory")
        try Data("blocked".utf8).write(to: blockedRoot)
        let historyStore = SearchHistoryStore(
            root: blockedRoot,
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        let old = makeRecord(query: "gut", works: [makeWork()], date: Date())
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        store.restoreHistoryRecord(old)
        let generation = await store.beginHistorySearch(displayQuery: "gut")

        await store.commitFirstUsableHistoryStage(
            displayQuery: "gut",
            startedAt: Date(),
            generation: generation
        )

        #expect(store.currentHistoryID == old.id)
        #expect(store.works == old.snapshot.allWorks)
        #expect(store.historyErrorMessage == "Search completed, but history could not be saved.")
        #expect(!store.isRefreshingHistory)
    }

    @Test func staleGenerationCannotCommitFirstUsableStage() async throws {
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
        let stale = await store.beginHistorySearch(displayQuery: "first")
        _ = await store.beginHistorySearch(displayQuery: "second")

        await store.commitFirstUsableHistoryStage(
            displayQuery: "first",
            startedAt: Date(),
            generation: stale
        )

        #expect(try await historyStore.loadRecord(id: first.id).snapshot.revision == 0)
        #expect(try await historyStore.loadRecord(id: second.id).snapshot.revision == 0)
    }
}
