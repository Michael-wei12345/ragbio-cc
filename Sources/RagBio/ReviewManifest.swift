import Foundation

enum ReviewOutputLanguage: String, Codable, CaseIterable, Equatable, Identifiable, Sendable {
    case english
    case simplifiedChinese

    var id: Self { self }

    var title: String {
        switch self {
        case .english: "English"
        case .simplifiedChinese: "中文"
        }
    }
}

enum ReviewManifestPaperDisposition: String, Codable, Equatable, Sendable {
    case included
    case duplicateURL
    case missingURL
}

struct ReviewManifestPaper: Codable, Equatable, Identifiable, Sendable {
    var id: String { identity.keys.first ?? workID }
    var order: Int
    var workID: String
    var title: String
    var venue: String
    var publicationYear: Int?
    var identity: PaperIdentity
    var selectedAt: Date
    var sourceURL: URL?
    var originalURL: URL?
    var disposition: ReviewManifestPaperDisposition
    var duplicateOfOrder: Int?
}

struct ReviewInputManifest: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var id: UUID
    var jobID: UUID
    var searchHistoryID: UUID
    var query: String
    var searchSnapshotAt: Date
    var createdAt: Date
    var outputLanguage: ReviewOutputLanguage?
    var papers: [ReviewManifestPaper]

    var resolvedOutputLanguage: ReviewOutputLanguage { outputLanguage ?? .english }

    var includedPapers: [ReviewManifestPaper] {
        papers.filter { $0.disposition == .included }
    }

    var usableURLCount: Int { includedPapers.count }
    var missingURLCount: Int { papers.count { $0.disposition == .missingURL } }
    var duplicateURLCount: Int { papers.count { $0.disposition == .duplicateURL } }

    static func make(
        record: SearchHistoryRecord,
        jobID: UUID,
        manifestID: UUID = UUID(),
        outputLanguage: ReviewOutputLanguage = .english,
        createdAt: Date = Date()
    ) -> ReviewInputManifest {
        let selection = SearchHistoryUseURLSelection.make(record: record)
        return ReviewInputManifest(
            schemaVersion: currentSchemaVersion,
            id: manifestID,
            jobID: jobID,
            searchHistoryID: record.id,
            query: record.displayQuery,
            searchSnapshotAt: record.lastSuccessfulSearchAt,
            createdAt: createdAt,
            outputLanguage: outputLanguage,
            papers: selection.entries.map { entry in
                ReviewManifestPaper(
                    order: entry.order,
                    workID: entry.paper.work.id,
                    title: entry.paper.work.title,
                    venue: entry.paper.work.venue,
                    publicationYear: entry.paper.work.publicationYear,
                    identity: entry.paper.identity,
                    selectedAt: entry.paper.selectedAt,
                    sourceURL: entry.url,
                    originalURL: entry.paper.work.landingPageURL,
                    disposition: entry.disposition,
                    duplicateOfOrder: entry.duplicateOfOrder
                )
            }
        )
    }
}

struct SearchHistoryUseURLSelection: Equatable {
    struct Entry: Equatable {
        var order: Int
        var paper: UsedPaper
        var url: URL?
        var disposition: ReviewManifestPaperDisposition
        var duplicateOfOrder: Int?
    }

    var entries: [Entry]

    var included: [Entry] { entries.filter { $0.disposition == .included } }
    var missingURLCount: Int { entries.count { $0.disposition == .missingURL } }

    static func make(record: SearchHistoryRecord) -> SearchHistoryUseURLSelection {
        var firstOrderByURL: [String: Int] = [:]
        let entries = record.useLedger.papers.enumerated().map { index, paper in
            let order = index + 1
            guard let url = SearchHistoryURLResolver.url(for: paper.work) else {
                return Entry(
                    order: order,
                    paper: paper,
                    url: nil,
                    disposition: .missingURL,
                    duplicateOfOrder: nil
                )
            }
            let value = url.absoluteString
            if let firstOrder = firstOrderByURL[value] {
                return Entry(
                    order: order,
                    paper: paper,
                    url: url,
                    disposition: .duplicateURL,
                    duplicateOfOrder: firstOrder
                )
            }
            firstOrderByURL[value] = order
            return Entry(
                order: order,
                paper: paper,
                url: url,
                disposition: .included,
                duplicateOfOrder: nil
            )
        }
        return SearchHistoryUseURLSelection(entries: entries)
    }
}
