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
}
