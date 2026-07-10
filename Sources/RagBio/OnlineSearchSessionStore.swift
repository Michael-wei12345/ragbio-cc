import Foundation

struct OnlineSearchSessionSnapshot: Codable, Equatable {
    static let currentVersion = 1

    let version: Int
    let savedAt: Date
    let query: String
    let lastQuery: String
    let searchMode: SearchMode
    let sort: SearchSort
    let fromYearEnabled: Bool
    let fromYear: Int
    let openAccessOnly: Bool
    let works: [Work]
    let aiRankedWorks: [Work]
    let totalCount: Int
    let currentPage: Int
    let selectedWorkID: Work.ID?
    let lastAIPlan: AISearchPlan?
    let aiReasons: [String: String]
    let aiScores: [String: Int]
    let aiEvidenceLevels: [String: String]
    let aiSearchNotice: String?
    let fullTextReviewSummaries: [String: LiteratureReviewSummary]
    let scanDecisions: [String: ScanDecisionRecord]?
    let currentEvidenceTable: EvidenceTable?
    let decisionFilter: ScanDecisionFilter?
    let currentFieldScanReport: FieldScanReport?
}

struct OnlineSearchSessionStore {
    private let fileURL: URL

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
        }
        fileURL = root.appendingPathComponent("online-search.json")
    }

    func load() -> OnlineSearchSessionSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(
                OnlineSearchSessionSnapshot.self,
                from: data
              ),
              snapshot.version == OnlineSearchSessionSnapshot.currentVersion else {
            return nil
        }
        return snapshot
    }

    func save(_ snapshot: OnlineSearchSessionSnapshot) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Search session restore is a convenience feature. Never fail the user-facing search flow
            // because this small cache could not be written.
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
