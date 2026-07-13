import Foundation
import Testing
@testable import RagBio

@Suite struct SearchHistoryStoreTests {
    @Test func saveWritesRecordBeforeSortedIndexAndLoadsItBack() async throws {
        let root = try makeTemporaryDirectory()
        let store = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
        let older = makeRecord(query: "older", works: [makeWork()], date: Date(timeIntervalSince1970: 1))
        let newer = makeRecord(
            query: "newer",
            works: [makeWork(id: "https://openalex.org/W2")],
            date: Date(timeIntervalSince1970: 2)
        )

        _ = try await store.save(older)
        let index = try await store.save(newer)

        #expect(index.summaries.map(\.displayQuery) == ["newer", "older"])
        let restored = try await store.loadRecord(id: older.id)
        #expect(restored == older)
    }

    @Test func damagedIndexRebuildsFromValidRecordsAndSkipsDamagedRecord() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
        let valid = makeRecord(query: "valid", works: [makeWork()], date: Date())
        _ = try await store.save(valid)
        try Data("broken".utf8).write(to: root.appendingPathComponent("records/broken.json"))
        try Data("broken".utf8).write(to: root.appendingPathComponent("index.json"))

        let rebuilt = try await store.loadIndex()

        #expect(rebuilt.summaries.map(\.id) == [valid.id])
    }

    @Test func useMutationIsSerializedAndPersistsMissingPaper() async throws {
        let root = try makeTemporaryDirectory()
        let store = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
        let record = makeRecord(query: "gut", works: [makeWork()], date: Date())
        _ = try await store.save(record)

        let updated = try await store.setUse(historyID: record.id, work: makeWork(), isUsed: true)

        #expect(updated.useLedger.papers.count == 1)
        let index = try await store.loadIndex()
        #expect(index.summaries.first?.useCount == 1)
    }

    @Test func snapshotUpdatePreservesUseAndRejectsOlderRevision() async throws {
        let root = try makeTemporaryDirectory()
        let store = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
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

        #expect(final.snapshot.searchTimingSummary == "newer")
        #expect(final.useLedger.papers.count == 1)
    }

    @Test func legacyResetDeletesOnlyProjectsAndAutosaveOnce() async throws {
        let root = try makeTemporaryDirectory()
        let legacy = root.appendingPathComponent("SearchSession")
        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("Projects"),
            withIntermediateDirectories: true
        )
        try Data("project".utf8).write(to: legacy.appendingPathComponent("Projects/index.json"))
        try Data("autosave".utf8).write(to: legacy.appendingPathComponent("online-search.json"))
        try Data("keep".utf8).write(to: root.appendingPathComponent("library.json"))

        let store = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: legacy
        )
        try await store.bootstrap()
        try Data("new legacy".utf8).write(to: legacy.appendingPathComponent("online-search.json"))
        try await store.bootstrap()

        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Projects").path))
        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("online-search.json").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("library.json").path))
    }

    @Test func failedSaveLeavesPreviousRecordReadable() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
        let record = makeRecord(query: "gut", works: [makeWork()], date: Date())
        _ = try await store.save(record)
        let indexURL = root.appendingPathComponent("index.json")
        try FileManager.default.removeItem(at: indexURL)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)

        var changed = record
        changed.displayQuery = "changed"
        do {
            _ = try await store.save(changed)
            Issue.record("Expected save to fail")
        } catch {}
        try FileManager.default.removeItem(at: indexURL)
        let restored = try await store.loadRecord(id: record.id)
        #expect(restored == record)
    }

    @Test func rebuildIgnoresValidDeletedTombstone() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
        let record = makeRecord(query: "gut", works: [makeWork()], date: Date())
        _ = try await store.save(record)
        let recordURL = root.appendingPathComponent("records/\(record.id.uuidString).json")
        let tombstoneURL = root.appendingPathComponent("records/\(record.id.uuidString).deleted")
        try FileManager.default.moveItem(at: recordURL, to: tombstoneURL)
        try Data("broken".utf8).write(to: root.appendingPathComponent("index.json"))

        let rebuilt = try await store.loadIndex()

        #expect(rebuilt.summaries.isEmpty)
    }

    @Test func saveRejectsDifferentIdentityForExistingNormalizedQuery() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
        let original = makeRecord(query: "Gut  Microbiota", works: [makeWork()], date: Date())
        let conflict = makeRecord(
            query: "gut microbiota",
            works: [makeWork(id: "https://openalex.org/W2")],
            date: Date().addingTimeInterval(1)
        )
        _ = try await store.save(original)

        var message: String?
        do {
            _ = try await store.save(conflict)
        } catch {
            message = error.localizedDescription
        }

        #expect(message == "A different search history already uses this normalized query.")
        let index = try await store.loadIndex()
        #expect(index.summaries.map(\.id) == [original.id])
        #expect(try await store.loadRecord(id: original.id) == original)
    }

    @Test func failedRecordTombstoneLeavesIndexAndRecordIntact() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let records = root.appendingPathComponent("records")
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
        let record = makeRecord(query: "gut", works: [makeWork()], date: Date())
        _ = try await store.save(record)
        try setPermissions(0o500, at: records)

        var didThrow = false
        do {
            _ = try await store.delete(id: record.id)
        } catch {
            didThrow = true
        }
        try setPermissions(0o700, at: records)

        #expect(didThrow)
        #expect(try await store.loadIndex().summaries.map(\.id) == [record.id])
        #expect(try await store.loadRecord(id: record.id) == record)
    }

    @Test func failedLegacyDeletionDoesNotWriteResetMarker() async throws {
        let root = try makeTemporaryDirectory()
        let legacy = root.appendingPathComponent("SearchSession")
        let projects = legacy.appendingPathComponent("Projects")
        let historyRoot = root.appendingPathComponent("SearchHistory")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try Data("project".utf8).write(to: projects.appendingPathComponent("index.json"))
        try setPermissions(0o500, at: legacy)
        let store = SearchHistoryStore(root: historyRoot, legacyRoot: legacy)

        var didThrow = false
        do {
            try await store.bootstrap()
        } catch {
            didThrow = true
        }

        #expect(didThrow)
        #expect(!FileManager.default.fileExists(atPath: historyRoot.appendingPathComponent(".legacy-reset-v1").path))
        try setPermissions(0o700, at: legacy)
        try await store.bootstrap()
        #expect(!FileManager.default.fileExists(atPath: projects.path))
    }
}

private func setPermissions(_ permissions: Int, at url: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: permissions)],
        ofItemAtPath: url.path
    )
}
