import Foundation

actor ReviewJobStore {
    private let root: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        self.root = root ?? Self.defaultRoot(fileManager: fileManager)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    func bootstrap(now: Date = Date()) throws -> [ReviewJob] {
        try ensureRoot()
        var restored = try jobs()
        for index in restored.indices where restored[index].status == .running {
            restored[index].status = .paused
            restored[index].stageDetail = "Paused when RagBio closed. Resume when ready."
            restored[index].updatedAt = now
            try write(restored[index])
        }
        return restored.sorted { $0.updatedAt > $1.updatedAt }
    }

    func create(
        manifest: ReviewInputManifest,
        now: Date = Date()
    ) throws -> ReviewJob {
        try ensureRoot()
        if try jobs().contains(where: { $0.status == .running }) {
            throw ReviewJobStoreError.anotherJobIsRunning
        }
        let version = (try jobs())
            .filter { $0.searchHistoryID == manifest.searchHistoryID }
            .map(\.version)
            .max(default: 0) + 1
        let job = ReviewJob(
            schemaVersion: ReviewJob.currentSchemaVersion,
            id: manifest.jobID,
            version: version,
            searchHistoryID: manifest.searchHistoryID,
            manifestID: manifest.id,
            query: manifest.query,
            status: .confirming,
            stage: .preparing,
            stageDetail: "Ready to generate from the current Use selection.",
            completedPaperCount: 0,
            totalPaperCount: manifest.usableURLCount,
            helperThreadID: nil,
            warningMessages: [],
            blockMessage: nil,
            artifacts: nil,
            createdAt: now,
            updatedAt: now,
            completedAt: nil
        )
        try createDirectories(for: job.id)
        try write(manifest)
        try write(job)
        return job
    }

    func jobs() throws -> [ReviewJob] {
        guard fileManager.fileExists(atPath: root.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { directory in
            let url = directory.appendingPathComponent("job.json")
            guard fileManager.fileExists(atPath: url.path) else { return nil }
            return try decoder.decode(ReviewJob.self, from: Data(contentsOf: url))
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func job(id: UUID) throws -> ReviewJob {
        let url = jobURL(id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ReviewJobStoreError.jobNotFound
        }
        return try decoder.decode(ReviewJob.self, from: Data(contentsOf: url))
    }

    func manifest(jobID: UUID) throws -> ReviewInputManifest {
        let url = manifestURL(jobID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ReviewJobStoreError.jobNotFound
        }
        return try decoder.decode(ReviewInputManifest.self, from: Data(contentsOf: url))
    }

    func latest(searchHistoryID: UUID) throws -> ReviewJob? {
        try jobs()
            .filter { $0.searchHistoryID == searchHistoryID }
            .max { $0.version < $1.version }
    }

    func update(
        id: UUID,
        status: ReviewJobStatus? = nil,
        stage: ReviewJobStage? = nil,
        detail: String? = nil,
        completedPaperCount: Int? = nil,
        helperThreadID: String? = nil,
        warnings: [String]? = nil,
        blockMessage: String? = nil,
        artifacts: ReviewJobArtifacts? = nil,
        now: Date = Date()
    ) throws -> ReviewJob {
        var job = try job(id: id)
        if status == .running,
           try jobs().contains(where: { $0.id != id && $0.status == .running }) {
            throw ReviewJobStoreError.anotherJobIsRunning
        }
        if let status { job.status = status }
        if let stage { job.stage = stage }
        if let detail { job.stageDetail = detail }
        if let completedPaperCount {
            job.completedPaperCount = min(max(0, completedPaperCount), job.totalPaperCount)
        }
        if let helperThreadID { job.helperThreadID = helperThreadID }
        if let warnings { job.warningMessages = warnings }
        job.blockMessage = blockMessage
        if let artifacts { job.artifacts = artifacts }
        if job.status == .completed { job.completedAt = now }
        job.updatedAt = now
        try write(job)
        return job
    }

    func outputDirectory(jobID: UUID) throws -> URL {
        let directory = jobDirectory(jobID).appendingPathComponent("outputs", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func workingDirectory(jobID: UUID) throws -> URL {
        let directory = jobDirectory(jobID).appendingPathComponent("working", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func deleteIncomplete(id: UUID) throws {
        let job = try job(id: id)
        guard job.status != .completed else { return }
        try fileManager.removeItem(at: jobDirectory(id))
    }

    private func write(_ job: ReviewJob) throws {
        let existing = try? self.job(id: job.id)
        if let existing,
           (existing.id != job.id ||
            existing.searchHistoryID != job.searchHistoryID ||
            existing.manifestID != job.manifestID) {
            throw ReviewJobStoreError.immutableIdentityChanged
        }
        try encoder.encode(job).write(to: jobURL(job.id), options: .atomic)
    }

    private func write(_ manifest: ReviewInputManifest) throws {
        try encoder.encode(manifest).write(to: manifestURL(manifest.jobID), options: .atomic)
    }

    private func ensureRoot() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func createDirectories(for id: UUID) throws {
        try fileManager.createDirectory(at: jobDirectory(id), withIntermediateDirectories: true)
        _ = try workingDirectory(jobID: id)
        _ = try outputDirectory(jobID: id)
    }

    private func jobDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func jobURL(_ id: UUID) -> URL {
        jobDirectory(id).appendingPathComponent("job.json")
    }

    private func manifestURL(_ id: UUID) -> URL {
        jobDirectory(id).appendingPathComponent("manifest.json")
    }

    private static func defaultRoot(fileManager: FileManager) -> URL {
        let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return support
            .appendingPathComponent("RagBio", isDirectory: true)
            .appendingPathComponent("Reviews", isDirectory: true)
    }
}

private extension Sequence where Element == Int {
    func max(default value: Int) -> Int { self.max() ?? value }
}
