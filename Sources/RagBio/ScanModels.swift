import Foundation

enum ScanDecision: String, Codable, CaseIterable, Identifiable {
    case unreviewed
    case use
    case maybe
    case exclude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .unreviewed: return "Unreviewed"
        case .use: return "Use in This Scan"
        case .maybe: return "Maybe"
        case .exclude: return "Exclude"
        }
    }

    var shortTitle: String {
        switch self {
        case .unreviewed: return "Unreviewed"
        case .use: return "Use"
        case .maybe: return "Maybe"
        case .exclude: return "Exclude"
        }
    }
}

struct ScanDecisionRecord: Codable, Equatable {
    var workID: String
    var decision: ScanDecision
    var note: String?
    var updatedAt: Date
}

enum ScanDecisionFilter: String, Codable, CaseIterable, Identifiable {
    case all
    case candidate
    case use
    case maybe
    case exclude
    case unreviewed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .candidate: return "Likely Primary"
        case .use: return "Use"
        case .maybe: return "Maybe"
        case .exclude: return "Exclude"
        case .unreviewed: return "Unreviewed"
        }
    }
}

struct EvidenceTable: Codable, Identifiable, Equatable {
    var id: UUID
    var query: String
    var generatedAt: Date
    var basedOnWorkIDs: [String]
    var rows: [EvidenceTableRow]
    var warning: String?
}

struct EvidenceTableRow: Codable, Identifiable, Equatable {
    var id: String { workID }

    var workID: String
    var title: String
    var year: Int?
    var authors: [String]
    var venue: String?
    var doi: String?
    var pmid: String?
    var pmcid: String?
    var openAlexID: String?

    var scanDecision: ScanDecision
    var accessStatus: EvidenceAccessStatus
    var aiScore: Double?
    var aiReason: String?
    var evidenceLevelLabel: String?

    var abstractText: String?
    var abstractEvidence: String?

    var summaryTopic: String?
    var summaryMethods: String?
    var summaryResults: String?
    var summaryKeyMetrics: String?
    var summaryOutlook: String?

    var sourceRefs: [EvidenceSourceRef]
    var userNote: String?
}

enum EvidenceAccessStatus: String, Codable, CaseIterable {
    case metadataOnly
    case abstractOnly
    case fullTextRead
    case userPDFImported
    case fullTextFailed
    case unknown

    var title: String {
        switch self {
        case .metadataOnly: return "Metadata only"
        case .abstractOnly: return "Abstract only"
        case .fullTextRead: return "Full text read"
        case .userPDFImported: return "User PDF imported"
        case .fullTextFailed: return "Full text failed"
        case .unknown: return "Unknown"
        }
    }

    var isFullTextSupported: Bool {
        self == .fullTextRead || self == .userPDFImported
    }
}

struct EvidenceSourceRef: Codable, Equatable {
    var field: String
    var section: String?
    var page: Int?
    var ordinal: Int?
    var quotePreview: String

    var locator: String {
        var values: [String] = []
        if let section { values.append(section) }
        if let ordinal { values.append("paragraph \(ordinal)") }
        if let page { values.append("page \(page)") }
        return values.isEmpty ? "source passage" : values.joined(separator: " · ")
    }
}

struct FieldScanReport: Codable, Identifiable, Equatable {
    var id: UUID
    var query: String
    var normalizedQuery: String?
    var generatedAt: Date
    var basedOnWorkIDs: [String]
    var inputSnapshot: FieldScanInputSnapshot

    var fieldOverview: String
    var mainThemes: [ResearchTheme]
    var keyFindings: [SupportedClaim]
    var conflictingEvidence: [SupportedClaim]
    var commonMethods: [SupportedClaim]
    var researchGaps: [SupportedClaim]
    var futureDirections: [SupportedClaim]
    var mustReadPapers: [MustReadPaper]
    var limitations: [String]
}

struct FieldScanInputSnapshot: Codable, Equatable {
    var rowCount: Int
    var fullTextSupportedCount: Int
    var abstractOnlyCount: Int
    var unreviewedCount: Int
    var generatedFromDecisions: Bool
}

struct ResearchTheme: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var summary: String
    var supportingWorkIDs: [String]
    var evidenceLevel: EvidenceSupportLevel
}

struct SupportedClaim: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var supportingWorkIDs: [String]
    var evidenceLevel: EvidenceSupportLevel
    var caution: String?
}

struct MustReadPaper: Codable, Identifiable, Equatable {
    var id: String { workID }
    var workID: String
    var title: String
    var reason: String
    var category: MustReadCategory
}

enum MustReadCategory: String, Codable, CaseIterable {
    case foundational
    case recent
    case methodologicallyUseful
    case fullTextAvailable
    case highlyRelevant

    var title: String {
        switch self {
        case .foundational: return "Foundational"
        case .recent: return "Recent"
        case .methodologicallyUseful: return "Methodologically useful"
        case .fullTextAvailable: return "Full text available"
        case .highlyRelevant: return "Highly relevant"
        }
    }
}

enum EvidenceSupportLevel: String, Codable, CaseIterable {
    case fullTextOnly
    case mixedFullTextAndAbstract
    case abstractOnly
    case metadataOnly

    var title: String {
        switch self {
        case .fullTextOnly: return "Full text only"
        case .mixedFullTextAndAbstract: return "Mixed full text and abstract"
        case .abstractOnly: return "Abstract only"
        case .metadataOnly: return "Metadata only"
        }
    }
}
