import Foundation

enum SearchHistoryStoreError: LocalizedError {
    case recordNotFound
    case corruptRecord
    case normalizedQueryConflict

    var errorDescription: String? {
        switch self {
        case .recordNotFound: return "Search history was not found."
        case .corruptRecord: return "This search history is damaged and could not be opened."
        case .normalizedQueryConflict: return "A different search history already uses this normalized query."
        }
    }
}

final class SearchHistoryMutationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
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
    // ponytail: zero in the app; nonzero only makes invalidation races deterministic in tests.
    private let persistenceDelay: Duration
    private let useReturnDelay: Duration
    private let firstUsableReturnDelay: Duration
    private let indexReturnDelay: Duration
    private(set) var isUseReturnDelayed = false
    private(set) var isFirstUsableReturnDelayed = false
    private(set) var isIndexReturnDelayed = false

    init(
        root customRoot: URL? = nil,
        legacyRoot customLegacyRoot: URL? = nil,
        persistenceDelay: Duration = .zero,
        useReturnDelay: Duration = .zero,
        firstUsableReturnDelay: Duration = .zero,
        indexReturnDelay: Duration = .zero
    ) {
        let applicationRoot = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("RagBio", isDirectory: true)
        root = customRoot ?? applicationRoot.appendingPathComponent("SearchHistory", isDirectory: true)
        records = root.appendingPathComponent("records", isDirectory: true)
        indexURL = root.appendingPathComponent("index.json")
        legacyResetMarkerURL = root.appendingPathComponent(".legacy-reset-v1")
        legacyRoot = customLegacyRoot ?? applicationRoot.appendingPathComponent("SearchSession", isDirectory: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.persistenceDelay = persistenceDelay
        self.useReturnDelay = useReturnDelay
        self.firstUsableReturnDelay = firstUsableReturnDelay
        self.indexReturnDelay = indexReturnDelay
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
        let legacyURLs = [
            legacyRoot.appendingPathComponent("Projects", isDirectory: true),
            legacyRoot.appendingPathComponent("online-search.json")
        ]
        for url in legacyURLs where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try Data("1".utf8).write(to: legacyResetMarkerURL, options: .atomic)
        index.legacyResetVersion = 1
        try writeIndex(index)
    }

    func loadIndex() async throws -> SearchHistoryIndex {
        let index = try readIndexOrRebuild()
        if indexReturnDelay != .zero {
            isIndexReturnDelayed = true
            try? await Task.sleep(for: indexReturnDelay)
            isIndexReturnDelayed = false
        }
        return index
    }

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
        guard let id = index.summaries.first(where: {
            $0.normalizedQuery == normalizedQuery
        })?.id else { return nil }
        return try loadRecord(id: id)
    }

    @discardableResult
    func save(_ record: SearchHistoryRecord) throws -> SearchHistoryIndex {
        var index = try readIndexOrRebuild()
        if index.summaries.contains(where: {
            $0.normalizedQuery == record.normalizedQuery && $0.id != record.id
        }) {
            throw SearchHistoryStoreError.normalizedQueryConflict
        }
        let url = recordURL(record.id)
        let previousRecordData = FileManager.default.fileExists(atPath: url.path)
            ? try Data(contentsOf: url)
            : nil
        do {
            try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
            try encoder.encode(record).write(to: url, options: .atomic)
            index.summaries.removeAll { $0.id == record.id }
            index.summaries.append(summary(record))
            index.summaries.sort { $0.lastSuccessfulSearchAt > $1.lastSuccessfulSearchAt }
            index.lastOpenedHistoryID = record.id
            try writeIndex(index)
            return index
        } catch {
            if let previousRecordData {
                try previousRecordData.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    func setUse(historyID: UUID, work: Work, isUsed: Bool) async throws -> SearchHistoryRecord {
        var record = try loadRecord(id: historyID)
        if isUsed {
            record.useLedger.mark(work)
        } else {
            record.useLedger.remove(work)
        }
        _ = try save(record)
        if useReturnDelay != .zero {
            isUseReturnDelayed = true
            try? await Task.sleep(for: useReturnDelay)
            isUseReturnDelayed = false
        }
        return record
    }

    func updateSnapshot(
        historyID: UUID,
        snapshot: SearchHistorySnapshot
    ) throws -> SearchHistoryRecord {
        var record = try loadRecord(id: historyID)
        guard snapshot.revision >= record.snapshot.revision else { return record }
        record.snapshot = snapshot
        _ = try save(record)
        return record
    }

    func saveFirstUsableStage(
        displayQuery: String,
        normalizedQuery: String,
        startedAt: Date,
        completedAt: Date,
        snapshot proposedSnapshot: SearchHistorySnapshot,
        mutationToken: SearchHistoryMutationToken
    ) async throws -> (record: SearchHistoryRecord, index: SearchHistoryIndex) {
        try await delayTokenizedPersistence()
        guard mutationToken.isValid else { throw CancellationError() }
        let prior = try record(normalizedQuery: normalizedQuery)
        var snapshot = proposedSnapshot
        snapshot.revision = max(
            snapshot.revision,
            (prior?.snapshot.revision ?? 0) + 1
        )
        let record = SearchHistoryRecord(
            schemaVersion: SearchHistoryRecord.currentSchemaVersion,
            id: prior?.id ?? UUID(),
            displayQuery: displayQuery,
            normalizedQuery: normalizedQuery,
            createdAt: prior?.createdAt ?? startedAt,
            lastSuccessfulSearchAt: completedAt,
            snapshot: snapshot,
            useLedger: prior?.useLedger ?? UseLedger()
        )
        let result = (record, try save(record))
        if firstUsableReturnDelay != .zero {
            isFirstUsableReturnDelayed = true
            try? await Task.sleep(for: firstUsableReturnDelay)
            isFirstUsableReturnDelayed = false
        }
        return result
    }

    func updateSnapshot(
        historyID: UUID,
        snapshot: SearchHistorySnapshot,
        mutationToken: SearchHistoryMutationToken
    ) async throws -> SearchHistoryRecord {
        try await delayTokenizedPersistence()
        guard mutationToken.isValid else { throw CancellationError() }
        return try updateSnapshot(historyID: historyID, snapshot: snapshot)
    }

    func setLastOpened(_ id: UUID?) throws -> SearchHistoryIndex {
        var index = try readIndexOrRebuild()
        index.lastOpenedHistoryID = id
        try writeIndex(index)
        return index
    }

    func delete(id: UUID) throws -> SearchHistoryIndex {
        var index = try readIndexOrRebuild()
        let url = recordURL(id)
        var tombstone: URL?
        if FileManager.default.fileExists(atPath: url.path) {
            let destination = records.appendingPathComponent(
                "\(id.uuidString)-\(UUID().uuidString).deleted"
            )
            try FileManager.default.moveItem(at: url, to: destination)
            tombstone = destination
        }
        index.summaries.removeAll { $0.id == id }
        if index.lastOpenedHistoryID == id {
            index.lastOpenedHistoryID = nil
        }
        do {
            try writeIndex(index)
        } catch {
            if let tombstone {
                try FileManager.default.moveItem(at: tombstone, to: url)
            }
            throw error
        }
        if let tombstone {
            try? FileManager.default.removeItem(at: tombstone)
        }
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

    private func delayTokenizedPersistence() async throws {
        guard persistenceDelay != .zero else { return }
        try await Task.sleep(for: persistenceDelay)
    }

    private func rebuildIndex() throws -> SearchHistoryIndex {
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let urls = try FileManager.default.contentsOfDirectory(
            at: records,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
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
        if index.lastOpenedHistoryID == id {
            index.lastOpenedHistoryID = nil
        }
        try writeIndex(index)
    }

    private func recordURL(_ id: UUID) -> URL {
        records.appendingPathComponent("\(id.uuidString).json")
    }
}
