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
        let matches = papers.indices.filter { papers[$0].identity.matches(identity) }
        if let first = matches.first {
            var mergedKeys: [String] = []
            for index in matches {
                mergedKeys += papers[index].identity.keys.filter { !mergedKeys.contains($0) }
            }
            mergedKeys += identity.keys.filter { !mergedKeys.contains($0) }
            let selectedAt = matches.map { papers[$0].selectedAt }.min() ?? date
            for index in matches.dropFirst().reversed() { papers.remove(at: index) }
            papers[first] = UsedPaper(
                identity: PaperIdentity(keys: mergedKeys),
                work: work,
                selectedAt: selectedAt
            )
        } else {
            papers.append(UsedPaper(identity: identity, work: work, selectedAt: date))
        }
    }

    mutating func reconcile(with works: [Work]) {
        for work in works where contains(work) { mark(work) }
    }

    mutating func remove(_ work: Work) {
        let identity = PaperIdentity(work: work)
        papers.removeAll { $0.identity.matches(identity) }
    }

    mutating func removeAll() {
        papers.removeAll()
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

enum SearchHistoryAIStage: String, Codable, Equatable {
    case localCandidates
    case coarseRanking
    case evidenceRanking
    case globalEvidenceRanking

    static func completed(
        coarse: AIRerankState,
        evidence: AISecondRerankState
    ) -> SearchHistoryAIStage {
        if case .completed = evidence { return .globalEvidenceRanking }
        if case .completed = coarse { return .coarseRanking }
        return .localCandidates
    }
}

struct SearchHistorySnapshot: Encodable, Equatable {
    var revision: Int
    var displayQuery: String
    var retrievalQuery: String
    var sort: SearchSort
    var fromYearEnabled: Bool
    var fromYear: Int
    var openAccessOnly: Bool
    var allWorks: [Work]
    var rankedWorks: [Work]
    var candidateWorks: [Work] = []
    var totalCount: Int
    var currentPage: Int
    var selectedWorkID: Work.ID?
    var lastAIPlan: AISearchPlan?
    var aiReasons: [String: String]
    var aiScores: [String: Int]
    var aiEvidenceLevels: [String: String]
    var evidenceCards: [String: StructuredEvidenceCard] = [:]
    var globalScoreFingerprint: String?
    var aiSearchNotice: String?
    var pubMedNotice: String?
    var searchTimingSummary: String?
    var fullTextReviewSummaries: [String: LiteratureReviewSummary]
    var articleSummaries: [String: String]
    var currentEvidenceTable: EvidenceTable?
    var currentFieldScanReport: FieldScanReport?
    var decisionFilter: ScanDecisionFilter = .all
    var completedAIStage: SearchHistoryAIStage?
}

extension SearchHistorySnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case revision, displayQuery, retrievalQuery, sort, fromYearEnabled, fromYear
        case openAccessOnly, allWorks, rankedWorks, candidateWorks, totalCount, currentPage
        case selectedWorkID
        case lastAIPlan, aiReasons, aiScores, aiEvidenceLevels, evidenceCards
        case globalScoreFingerprint
        case aiSearchNotice, pubMedNotice
        case searchTimingSummary, fullTextReviewSummaries, articleSummaries
        case currentEvidenceTable, currentFieldScanReport, decisionFilter, completedAIStage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        revision = try values.decode(Int.self, forKey: .revision)
        displayQuery = try values.decode(String.self, forKey: .displayQuery)
        retrievalQuery = try values.decode(String.self, forKey: .retrievalQuery)
        sort = try values.decode(SearchSort.self, forKey: .sort)
        fromYearEnabled = try values.decode(Bool.self, forKey: .fromYearEnabled)
        fromYear = try values.decode(Int.self, forKey: .fromYear)
        openAccessOnly = try values.decode(Bool.self, forKey: .openAccessOnly)
        allWorks = try values.decode([Work].self, forKey: .allWorks)
        rankedWorks = try values.decode([Work].self, forKey: .rankedWorks)
        candidateWorks = try values.decodeIfPresent([Work].self, forKey: .candidateWorks)
            ?? rankedWorks
        totalCount = try values.decode(Int.self, forKey: .totalCount)
        currentPage = try values.decode(Int.self, forKey: .currentPage)
        selectedWorkID = try values.decodeIfPresent(Work.ID.self, forKey: .selectedWorkID)
        lastAIPlan = try values.decodeIfPresent(AISearchPlan.self, forKey: .lastAIPlan)
        aiReasons = try values.decode([String: String].self, forKey: .aiReasons)
        aiScores = try values.decode([String: Int].self, forKey: .aiScores)
        aiEvidenceLevels = try values.decode([String: String].self, forKey: .aiEvidenceLevels)
        evidenceCards = try values.decodeIfPresent(
            [String: StructuredEvidenceCard].self,
            forKey: .evidenceCards
        ) ?? [:]
        globalScoreFingerprint = try values.decodeIfPresent(
            String.self,
            forKey: .globalScoreFingerprint
        )
        aiSearchNotice = try values.decodeIfPresent(String.self, forKey: .aiSearchNotice)
        pubMedNotice = try values.decodeIfPresent(String.self, forKey: .pubMedNotice)
        searchTimingSummary = try values.decodeIfPresent(String.self, forKey: .searchTimingSummary)
        fullTextReviewSummaries = try values.decode(
            [String: LiteratureReviewSummary].self,
            forKey: .fullTextReviewSummaries
        )
        articleSummaries = try values.decode([String: String].self, forKey: .articleSummaries)
        currentEvidenceTable = try values.decodeIfPresent(
            EvidenceTable.self,
            forKey: .currentEvidenceTable
        )
        currentFieldScanReport = try values.decodeIfPresent(
            FieldScanReport.self,
            forKey: .currentFieldScanReport
        )
        let savedFilter = try values.decodeIfPresent(String.self, forKey: .decisionFilter)
        decisionFilter = savedFilter.flatMap(ScanDecisionFilter.init(rawValue:))
            .flatMap { [.all, .candidate, .use].contains($0) ? $0 : nil }
            ?? .all
        completedAIStage = try values.decodeIfPresent(
            SearchHistoryAIStage.self,
            forKey: .completedAIStage
        )
    }
}
