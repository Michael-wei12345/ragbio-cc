import Foundation

typealias OnlineSearchSession = OnlineSearchSessionSnapshot

struct OnlineSearchProjectIndex: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var projects: [OnlineSearchProjectSummary]
    var lastOpenedProjectID: UUID?
}

struct OnlineSearchProjectSummary: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var query: String
    var createdAt: Date
    var updatedAt: Date
    var paperCount: Int
    var useCount: Int
    var maybeCount: Int
    var excludeCount: Int
    var hasEvidenceTable: Bool
    var hasFieldScanReport: Bool
}

struct OnlineSearchProject: Codable, Identifiable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date

    var session: OnlineSearchSession

    var evidenceTables: [EvidenceTable]
    var currentEvidenceTableID: UUID?
    var fieldScanReports: [FieldScanReport]
    var currentFieldScanReportID: UUID?

    var userNotes: String?
}

enum OnlineSearchProjectStoreError: LocalizedError {
    case invalidName
    case projectNotFound

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Project name cannot be empty."
        case .projectNotFound:
            return "Project was not found."
        }
    }
}

struct OnlineSearchProjectStore {
    private let directoryURL: URL
    private let indexURL: URL

    init(root customRoot: URL? = nil) {
        let root: URL
        if let customRoot {
            root = customRoot
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            root = applicationSupport
                .appendingPathComponent("RagBio", isDirectory: true)
                .appendingPathComponent("SearchSession", isDirectory: true)
                .appendingPathComponent("Projects", isDirectory: true)
        }
        directoryURL = root
        indexURL = root.appendingPathComponent("index.json")
    }

    func loadIndex() -> OnlineSearchProjectIndex {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(OnlineSearchProjectIndex.self, from: data),
              index.schemaVersion == OnlineSearchProjectIndex.currentSchemaVersion else {
            return emptyIndex()
        }
        return OnlineSearchProjectIndex(
            schemaVersion: index.schemaVersion,
            projects: sorted(index.projects),
            lastOpenedProjectID: index.lastOpenedProjectID
        )
    }

    func loadProject(id: UUID) throws -> OnlineSearchProject {
        let url = projectURL(id)
        guard let data = try? Data(contentsOf: url) else {
            throw OnlineSearchProjectStoreError.projectNotFound
        }
        return try JSONDecoder().decode(OnlineSearchProject.self, from: data)
    }

    func loadLastOpenedProject() -> OnlineSearchProject? {
        guard let id = loadIndex().lastOpenedProjectID else { return nil }
        return try? loadProject(id: id)
    }

    func createProject(
        name: String,
        session: OnlineSearchSession,
        userNotes: String? = nil
    ) throws -> OnlineSearchProject {
        let cleanName = cleanedName(name)
        guard !cleanName.isEmpty else {
            throw OnlineSearchProjectStoreError.invalidName
        }
        let now = Date()
        let project = OnlineSearchProject(
            schemaVersion: OnlineSearchProject.currentSchemaVersion,
            id: UUID(),
            name: cleanName,
            createdAt: now,
            updatedAt: now,
            session: session,
            evidenceTables: session.currentEvidenceTable.map { [$0] } ?? [],
            currentEvidenceTableID: session.currentEvidenceTable?.id,
            fieldScanReports: session.currentFieldScanReport.map { [$0] } ?? [],
            currentFieldScanReportID: session.currentFieldScanReport?.id,
            userNotes: userNotes
        )
        try saveProject(project, markLastOpened: true)
        return project
    }

    func updateProject(
        id: UUID,
        session: OnlineSearchSession
    ) throws -> OnlineSearchProject {
        var project = try loadProject(id: id)
        project.updatedAt = Date()
        project.session = session
        if let table = session.currentEvidenceTable {
            project.evidenceTables = upsert(table, into: project.evidenceTables)
            project.currentEvidenceTableID = table.id
        }
        if let report = session.currentFieldScanReport {
            project.fieldScanReports = upsert(report, into: project.fieldScanReports)
            project.currentFieldScanReportID = report.id
        }
        try saveProject(project, markLastOpened: true)
        return project
    }

    func renameProject(id: UUID, name: String) throws -> OnlineSearchProject {
        let cleanName = cleanedName(name)
        guard !cleanName.isEmpty else {
            throw OnlineSearchProjectStoreError.invalidName
        }
        var project = try loadProject(id: id)
        project.name = cleanName
        project.updatedAt = Date()
        try saveProject(project, markLastOpened: true)
        return project
    }

    func duplicateProject(id: UUID, name: String? = nil) throws -> OnlineSearchProject {
        let source = try loadProject(id: id)
        let now = Date()
        let cleanName = cleanedName(name ?? "\(source.name) Copy")
        guard !cleanName.isEmpty else {
            throw OnlineSearchProjectStoreError.invalidName
        }
        var copy = source
        copy.id = UUID()
        copy.name = cleanName
        copy.createdAt = now
        copy.updatedAt = now
        try saveProject(copy, markLastOpened: true)
        return copy
    }

    func deleteProject(id: UUID) throws {
        var index = loadIndex()
        guard index.projects.contains(where: { $0.id == id }) else {
            throw OnlineSearchProjectStoreError.projectNotFound
        }
        try? FileManager.default.removeItem(at: projectURL(id))
        index.projects.removeAll { $0.id == id }
        if index.lastOpenedProjectID == id {
            index.lastOpenedProjectID = nil
        }
        try saveIndex(index)
    }

    func setLastOpenedProjectID(_ id: UUID?) {
        var index = loadIndex()
        index.lastOpenedProjectID = id
        try? saveIndex(index)
    }

    private func saveProject(
        _ project: OnlineSearchProject,
        markLastOpened: Bool
    ) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try encoder().encode(project)
        try data.write(to: projectURL(project.id), options: .atomic)

        var index = loadIndex()
        index.projects.removeAll { $0.id == project.id }
        index.projects.append(Self.summary(for: project))
        index.projects = sorted(index.projects)
        if markLastOpened {
            index.lastOpenedProjectID = project.id
        }
        try saveIndex(index)
    }

    private func saveIndex(_ index: OnlineSearchProjectIndex) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try encoder().encode(index)
        try data.write(to: indexURL, options: .atomic)
    }

    private func projectURL(_ id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func emptyIndex() -> OnlineSearchProjectIndex {
        OnlineSearchProjectIndex(
            schemaVersion: OnlineSearchProjectIndex.currentSchemaVersion,
            projects: [],
            lastOpenedProjectID: nil
        )
    }

    private func sorted(
        _ projects: [OnlineSearchProjectSummary]
    ) -> [OnlineSearchProjectSummary] {
        projects.sorted {
            if $0.updatedAt == $1.updatedAt {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func cleanedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func summary(
        for project: OnlineSearchProject
    ) -> OnlineSearchProjectSummary {
        let decisions = project.session.scanDecisions ?? [:]
        return OnlineSearchProjectSummary(
            id: project.id,
            name: project.name,
            query: project.session.lastQuery.isEmpty
                ? project.session.query
                : project.session.lastQuery,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt,
            paperCount: project.session.works.count,
            useCount: decisions.values.filter { $0.decision == .use }.count,
            maybeCount: decisions.values.filter { $0.decision == .maybe }.count,
            excludeCount: decisions.values.filter { $0.decision == .exclude }.count,
            hasEvidenceTable: project.session.currentEvidenceTable != nil
                || !project.evidenceTables.isEmpty,
            hasFieldScanReport: project.session.currentFieldScanReport != nil
                || !project.fieldScanReports.isEmpty
        )
    }

    private func upsert(
        _ table: EvidenceTable,
        into tables: [EvidenceTable]
    ) -> [EvidenceTable] {
        var values = tables.filter { $0.id != table.id }
        values.append(table)
        return values.sorted { $0.generatedAt > $1.generatedAt }
    }

    private func upsert(
        _ report: FieldScanReport,
        into reports: [FieldScanReport]
    ) -> [FieldScanReport] {
        var values = reports.filter { $0.id != report.id }
        values.append(report)
        return values.sorted { $0.generatedAt > $1.generatedAt }
    }
}
