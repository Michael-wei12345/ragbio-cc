import Foundation

enum SearchQueryIdentity {
    static func normalize(_ value: String) -> String {
        value
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

struct PaperIdentity: Codable, Hashable {
    let keys: [String]

    init(work: Work) {
        var values: [String] = []
        if let doi = work.normalizedDOI?.lowercased(), !doi.isEmpty {
            values.append("doi:\(doi)")
        }
        if let pmid = work.normalizedPMID?.lowercased(), !pmid.isEmpty {
            values.append("pmid:\(pmid)")
        }
        let openAlex = work.shortID.lowercased()
        if openAlex.hasPrefix("w"), openAlex.dropFirst().allSatisfy(\.isNumber) {
            values.append("openalex:\(openAlex)")
        }
        let title = Self.words(work.title)
        let firstAuthor = Self.words(work.authorships.first?.author.displayName ?? "")
        if !title.isEmpty, let year = work.publicationYear, !firstAuthor.isEmpty {
            values.append("fallback:\(title)|\(year)|\(firstAuthor)")
        }
        var seen = Set<String>()
        keys = values.filter { seen.insert($0).inserted }
    }

    func matches(_ other: PaperIdentity) -> Bool {
        for prefix in ["doi:", "pmid:", "openalex:", "fallback:"] {
            let left = keys.first { $0.hasPrefix(prefix) }
            let right = other.keys.first { $0.hasPrefix(prefix) }
            if let left, let right { return left == right }
        }
        return false
    }

    private static func words(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

extension PaperIdentity {
    init(keys: [String]) { self.keys = keys }
}

struct UsedPaper: Codable, Equatable, Identifiable {
    var id: String { identity.keys.first ?? work.id }
    var identity: PaperIdentity
    var work: Work
    var selectedAt: Date
}

struct UseLedger: Codable, Equatable {
    private(set) var papers: [UsedPaper] = []

    mutating func mark(_ work: Work, at date: Date = Date()) {
        let identity = PaperIdentity(work: work)
        if let index = papers.firstIndex(where: { $0.identity.matches(identity) }) {
            let mergedKeys = papers[index].identity.keys + identity.keys.filter {
                !papers[index].identity.keys.contains($0)
            }
            papers[index].identity = PaperIdentity(keys: mergedKeys)
            papers[index].work = work
        } else {
            papers.append(UsedPaper(identity: identity, work: work, selectedAt: date))
        }
    }

    mutating func remove(_ work: Work) {
        let identity = PaperIdentity(work: work)
        papers.removeAll { $0.identity.matches(identity) }
    }

    func contains(_ work: Work) -> Bool {
        let identity = PaperIdentity(work: work)
        return papers.contains { $0.identity.matches(identity) }
    }
}

struct SearchHistoryIndex: Codable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var summaries: [SearchHistorySummary]
    var lastOpenedHistoryID: UUID?
    var legacyResetVersion: Int
}

struct SearchHistorySummary: Codable, Equatable, Identifiable {
    var id: UUID
    var displayQuery: String
    var normalizedQuery: String
    var createdAt: Date
    var lastSuccessfulSearchAt: Date
    var paperCount: Int
    var useCount: Int
}

struct SearchHistoryRecord: Codable, Equatable, Identifiable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var id: UUID
    var displayQuery: String
    var normalizedQuery: String
    var createdAt: Date
    var lastSuccessfulSearchAt: Date
    var snapshot: SearchHistorySnapshot
    var useLedger: UseLedger
}

struct SearchHistorySnapshot: Codable, Equatable {
    var revision: Int
    var displayQuery: String
    var retrievalQuery: String
    var sort: SearchSort
    var fromYearEnabled: Bool
    var fromYear: Int
    var openAccessOnly: Bool
    var allWorks: [Work]
    var rankedWorks: [Work]
    var totalCount: Int
    var currentPage: Int
    var selectedWorkID: Work.ID?
    var lastAIPlan: AISearchPlan?
    var aiReasons: [String: String]
    var aiScores: [String: Int]
    var aiEvidenceLevels: [String: String]
    var aiSearchNotice: String?
    var pubMedNotice: String?
    var searchTimingSummary: String?
    var fullTextReviewSummaries: [String: LiteratureReviewSummary]
    var articleSummaries: [String: String]
    var currentEvidenceTable: EvidenceTable?
    var currentFieldScanReport: FieldScanReport?
}
