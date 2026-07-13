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
}
