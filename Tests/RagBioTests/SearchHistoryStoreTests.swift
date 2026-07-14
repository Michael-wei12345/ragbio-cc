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
        #expect(try await store.loadRecord(id: valid.id) == valid)
    }

    @Test func loadRejectsValidJSONWhoseRequestedAndStoredIDsDiffer() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
        let requested = makeRecord(query: "requested", works: [makeWork()], date: Date())
        _ = try await store.save(requested)
        let foreign = makeRecord(query: "foreign", works: [makeWork()], date: Date())
        try JSONEncoder().encode(foreign).write(
            to: root.appendingPathComponent("records/\(requested.id.uuidString).json")
        )

        var message: String?
        do {
            _ = try await store.loadRecord(id: requested.id)
        } catch {
            message = error.localizedDescription
        }

        #expect(message == "This search history is damaged and could not be opened.")
        #expect(try await store.loadIndex().summaries.isEmpty)
    }

    @Test func saveRejectsSemanticIdentityMismatchBeforeWriting() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
        var invalid = makeRecord(query: "valid", works: [makeWork()], date: Date())
        invalid.normalizedQuery = "wrong"

        await #expect(throws: SearchHistoryStoreError.self) {
            _ = try await store.save(invalid)
        }
        #expect(try await store.loadIndex().summaries.isEmpty)
    }

    @Test func semanticInvalidIndexesRebuildWithoutReadingRecordBodiesOnValidPath() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
        let older = makeRecord(query: "older", works: [], date: Date(timeIntervalSince1970: 1))
        let newer = makeRecord(query: "newer", works: [], date: Date(timeIntervalSince1970: 2))
        _ = try await store.save(older)
        _ = try await store.save(newer)
        let indexURL = root.appendingPathComponent("index.json")
        let validData = try Data(contentsOf: indexURL)

        for corruption in 0..<6 {
            var object = try #require(
                JSONSerialization.jsonObject(with: validData) as? [String: Any]
            )
            var summaries = try #require(object["summaries"] as? [[String: Any]])
            switch corruption {
            case 0:
                summaries[1]["id"] = summaries[0]["id"]
            case 1:
                summaries[1]["displayQuery"] = summaries[0]["displayQuery"]
                summaries[1]["normalizedQuery"] = summaries[0]["normalizedQuery"]
            case 2:
                summaries[0]["normalizedQuery"] = "bad normalization"
            case 3:
                summaries.reverse()
            case 4:
                object["lastOpenedHistoryID"] = UUID().uuidString
            default:
                summaries[0]["paperCount"] = -1
            }
            object["summaries"] = summaries
            try JSONSerialization.data(withJSONObject: object).write(to: indexURL)

            let rebuilt = try await store.loadIndex()

            #expect(rebuilt.summaries.map(\.id) == [newer.id, older.id])
        }
    }

    @Test func rebuildValidatesFilenameIdentityAndDeduplicatesNewestSemanticRecord() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let records = root.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let older = makeRecord(query: "duplicate", works: [], date: Date(timeIntervalSince1970: 1))
        let unique = makeRecord(query: "unique", works: [], date: Date(timeIntervalSince1970: 3))
        let newer = makeRecord(query: " DUPLICATE ", works: [], date: Date(timeIntervalSince1970: 4))
        var semanticInvalid = makeRecord(query: "invalid", works: [], date: Date(timeIntervalSince1970: 5))
        semanticInvalid.snapshot.displayQuery = "different"
        let filenameMismatch = makeRecord(query: "mismatch", works: [], date: Date(timeIntervalSince1970: 6))
        let encoder = JSONEncoder()
        for record in [older, unique, newer, semanticInvalid] {
            try encoder.encode(record).write(
                to: records.appendingPathComponent("\(record.id.uuidString).json")
            )
        }
        try encoder.encode(filenameMismatch).write(
            to: records.appendingPathComponent("\(UUID().uuidString).json")
        )
        try Data("broken".utf8).write(to: root.appendingPathComponent("index.json"))
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )

        let rebuilt = try await store.loadIndex()

        #expect(rebuilt.summaries.map(\.id) == [newer.id, unique.id])
        #expect(rebuilt.summaries.map(\.normalizedQuery) == ["duplicate", "unique"])
    }

    @Test func deletingRebuiltQueryRemovesEveryValidShadowSoItCannotResurrect() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let records = root.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let oldWork = makeWork(id: "old", doi: "10.1000/old")
        let newWork = makeWork(id: "new", doi: "10.1000/new")
        var oldLedger = UseLedger(); oldLedger.mark(oldWork)
        var newLedger = UseLedger(); newLedger.mark(newWork)
        let older = makeRecord(
            query: "duplicate",
            works: [oldWork],
            date: Date(timeIntervalSince1970: 1),
            useLedger: oldLedger
        )
        let newer = makeRecord(
            query: " DUPLICATE ",
            works: [newWork],
            date: Date(timeIntervalSince1970: 3),
            useLedger: newLedger
        )
        let unrelated = makeRecord(
            query: "unrelated",
            works: [makeWork(id: "other", doi: "10.1000/other")],
            date: Date(timeIntervalSince1970: 2)
        )
        let encoder = JSONEncoder()
        for record in [older, newer, unrelated] {
            try encoder.encode(record).write(
                to: records.appendingPathComponent("\(record.id.uuidString).json")
            )
        }
        let corruptURL = records.appendingPathComponent("corrupt.json")
        try Data("corrupt".utf8).write(to: corruptURL)
        try Data("broken".utf8).write(to: root.appendingPathComponent("index.json"))
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        #expect(try await store.loadIndex().summaries.map(\.id) == [newer.id, unrelated.id])

        _ = try await store.delete(id: newer.id)
        try Data("broken again".utf8).write(to: root.appendingPathComponent("index.json"))
        let rebuilt = try await store.loadIndex()

        #expect(rebuilt.summaries.map(\.id) == [unrelated.id])
        #expect(!rebuilt.summaries.contains { $0.normalizedQuery == "duplicate" })
        #expect(!FileManager.default.fileExists(atPath: records.appendingPathComponent("\(older.id.uuidString).json").path))
        #expect(!FileManager.default.fileExists(atPath: records.appendingPathComponent("\(newer.id.uuidString).json").path))
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
        #expect(try await store.loadRecord(id: unrelated.id) == unrelated)
    }

    @Test func failedQueryWideDeleteRollsBackEveryMovedShadow() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let records = root.appendingPathComponent("records")
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
        let visible = makeRecord(query: "duplicate", works: [], date: Date(timeIntervalSince1970: 2))
        let shadow = makeRecord(query: " DUPLICATE ", works: [], date: Date(timeIntervalSince1970: 1))
        _ = try await store.save(visible)
        try JSONEncoder().encode(shadow).write(
            to: records.appendingPathComponent("\(shadow.id.uuidString).json")
        )
        let corruptURL = records.appendingPathComponent("corrupt.json")
        try Data("corrupt".utf8).write(to: corruptURL)
        try setPermissions(0o500, at: root)

        var didThrow = false
        do {
            _ = try await store.delete(id: visible.id)
        } catch {
            didThrow = true
        }
        try setPermissions(0o700, at: root)

        #expect(didThrow)
        #expect(try await store.loadIndex().summaries.map(\.id) == [visible.id])
        #expect(FileManager.default.fileExists(atPath: records.appendingPathComponent("\(visible.id.uuidString).json").path))
        #expect(FileManager.default.fileExists(atPath: records.appendingPathComponent("\(shadow.id.uuidString).json").path))
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    @Test func failedIndividualRollbackLeavesRecoverableMarkerThatBootstrapRestores() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let records = root.appendingPathComponent("records")
        let recovery = root.appendingPathComponent("recovery")
        let visible = makeRecord(query: "duplicate", works: [], date: Date(timeIntervalSince1970: 2))
        let shadow = makeRecord(query: " DUPLICATE ", works: [], date: Date(timeIntervalSince1970: 1))
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession"),
            rollbackRestoreFailureID: shadow.id
        )
        try await store.bootstrap()
        _ = try await store.save(visible)
        try JSONEncoder().encode(shadow).write(
            to: records.appendingPathComponent("\(shadow.id.uuidString).json")
        )
        let corruptURL = records.appendingPathComponent("corrupt.json")
        try Data("corrupt".utf8).write(to: corruptURL)
        try setPermissions(0o500, at: root)

        var message = ""
        do {
            _ = try await store.delete(id: visible.id)
        } catch {
            message = error.localizedDescription
        }
        try setPermissions(0o700, at: root)

        let rollbackURLs = try FileManager.default.contentsOfDirectory(
            at: recovery,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "rollback" }
        #expect(message.contains("rollback"))
        #expect(message.contains(shadow.id.uuidString))
        #expect(rollbackURLs.count == 1)
        #expect(rollbackURLs.first?.lastPathComponent.contains(shadow.id.uuidString) == true)
        #expect(try FileManager.default.contentsOfDirectory(
            at: records,
            includingPropertiesForKeys: nil
        ).allSatisfy { $0.pathExtension != "rollback" })
        #expect(!FileManager.default.fileExists(
            atPath: records.appendingPathComponent("\(shadow.id.uuidString).json").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: records.appendingPathComponent("\(visible.id.uuidString).json").path
        ))
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))

        try Data("force rebuild".utf8).write(to: root.appendingPathComponent("index.json"))
        let restarted = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        try await restarted.bootstrap()

        #expect(try await restarted.loadIndex().summaries.map(\.id) == [visible.id])
        #expect(try await restarted.loadRecord(id: shadow.id) == shadow)
        #expect(try FileManager.default.contentsOfDirectory(
            at: recovery,
            includingPropertiesForKeys: nil
        ).allSatisfy { $0.pathExtension != "rollback" })
        #expect(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    @Test func firstUsableStageReconcilesBridgedUseForPersistenceCountAndExport() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let store = SearchHistoryStore(
            root: root,
            legacyRoot: root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        )
        try await store.bootstrap()
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
        let prior = makeRecord(query: "bridge", works: [doiOnly], date: Date(), useLedger: ledger)
        _ = try await store.save(prior)
        let snapshot = makeSnapshot(query: "bridge", works: [bridge])

        let result = try await store.saveFirstUsableStage(
            displayQuery: "bridge",
            normalizedQuery: "bridge",
            startedAt: Date(),
            completedAt: Date().addingTimeInterval(1),
            snapshot: snapshot,
            mutationToken: SearchHistoryMutationToken()
        )

        #expect(result.record.useLedger.papers.count == 1)
        #expect(result.record.useLedger.papers.first?.work.id == bridge.id)
        #expect(result.index.summaries.first?.useCount == 1)
        let disk = try await store.loadRecord(id: prior.id)
        #expect(disk.useLedger.papers.count == 1)
        let export = SearchHistoryExportBuilder.make(records: [disk])
        #expect(export.urlCount == 1)
        #expect(export.text.components(separatedBy: "https://doi.org/10.1000/bridge").count - 1 == 1)
    }

    @Test func largeValidIndexLoadsNewestFirstWithoutDecodingDamagedRecord() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let legacyRoot = root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        let writer = SearchHistoryStore(root: root, legacyRoot: legacyRoot)
        try await writer.bootstrap()
        var damagedID: UUID?
        for offset in 0..<500 {
            let record = makeRecord(
                query: "query \(offset)",
                works: offset == 499 ? [makeWork()] : [],
                date: Date(timeIntervalSince1970: TimeInterval(offset))
            )
            _ = try await writer.save(record)
            if offset == 250 { damagedID = record.id }
        }
        let capturedDamagedID = try #require(damagedID)
        try Data("broken".utf8).write(
            to: root.appendingPathComponent("records/\(capturedDamagedID.uuidString).json")
        )

        let reader = SearchHistoryStore(root: root, legacyRoot: legacyRoot)
        let startedAt = Date()
        try await reader.bootstrap()
        let index = try await reader.loadIndex()
        let elapsed = Date().timeIntervalSince(startedAt)
        print("Task 8 index-only bootstrap/load for 500 summaries: \(elapsed) seconds")

        #expect(index.summaries.count == 500)
        #expect(index.summaries.first?.displayQuery == "query 499")
        #expect(index.summaries.last?.displayQuery == "query 0")
        let newest = try #require(index.summaries.first)
        #expect(try await reader.loadRecord(id: newest.id).snapshot.rankedWorks.count == 1)
    }

    @Test func validIndexBootstrapDoesNotEnumerateRecordDirectory() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("SearchHistory")
        let records = root.appendingPathComponent("records")
        let legacyRoot = root.deletingLastPathComponent().appendingPathComponent("SearchSession")
        let writer = SearchHistoryStore(root: root, legacyRoot: legacyRoot)
        try await writer.bootstrap()
        let record = makeRecord(query: "indexed", works: [makeWork()], date: Date())
        _ = try await writer.save(record)
        for offset in 0..<200 {
            try Data("junk".utf8).write(
                to: records.appendingPathComponent("unrelated-\(offset).deleted")
            )
        }
        try setPermissions(0o300, at: records)
        defer { try? setPermissions(0o700, at: records) }
        let reader = SearchHistoryStore(root: root, legacyRoot: legacyRoot)

        try await reader.bootstrap()
        let index = try await reader.loadIndex()

        #expect(index.summaries.map(\.id) == [record.id])
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
        let fullText = root.appendingPathComponent("FullText")
        let library = root.appendingPathComponent("Library")
        let settings = root.appendingPathComponent("Settings")
        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("Projects"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: fullText, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        try Data("project".utf8).write(to: legacy.appendingPathComponent("Projects/index.json"))
        try Data("autosave".utf8).write(to: legacy.appendingPathComponent("online-search.json"))
        let preservedURLs = [
            legacy.appendingPathComponent("unrelated.json"),
            fullText.appendingPathComponent("cached-work.json"),
            library.appendingPathComponent("catalog.json"),
            library.appendingPathComponent("paper.pdf"),
            settings.appendingPathComponent("providers-and-api-keys.json"),
            root.appendingPathComponent("preferences.json")
        ]
        for url in preservedURLs {
            try Data("keep".utf8).write(to: url)
        }

        let historyRoot = root.appendingPathComponent("SearchHistory")
        let firstLaunch = SearchHistoryStore(
            root: historyRoot,
            legacyRoot: legacy
        )
        try await firstLaunch.bootstrap()
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Projects").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.appendingPathComponent("online-search.json").path))
        #expect(FileManager.default.fileExists(atPath: historyRoot.appendingPathComponent(".legacy-reset-v1").path))
        #expect(try await firstLaunch.loadIndex().legacyResetVersion == 1)
        for url in preservedURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        try FileManager.default.createDirectory(
            at: legacy.appendingPathComponent("Projects"),
            withIntermediateDirectories: true
        )
        try Data("new project".utf8).write(to: legacy.appendingPathComponent("Projects/index.json"))
        try Data("new legacy".utf8).write(to: legacy.appendingPathComponent("online-search.json"))
        let restarted = SearchHistoryStore(root: historyRoot, legacyRoot: legacy)
        try await restarted.bootstrap()

        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("Projects/index.json").path))
        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("online-search.json").path))
        for url in preservedURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
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
        changed.normalizedQuery = "changed"
        changed.snapshot.displayQuery = "changed"
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
