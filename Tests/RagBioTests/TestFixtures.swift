import Foundation
@testable import RagBio

func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeWork(
    id: String = "https://openalex.org/W1",
    doi: String? = "https://doi.org/10.1000/example",
    pmid: String? = "https://pubmed.ncbi.nlm.nih.gov/123/",
    title: String = "Example Paper",
    year: Int? = 2024,
    author: String? = "A. Author",
    publisherURL: String? = "https://publisher.example/article",
    bestPublisherURL: String? = nil
) -> Work {
    Work(
        id: id,
        doi: doi,
        title: title,
        publicationDate: year.map { "\($0)-01-01" },
        publicationYear: year,
        citedByCount: 0,
        authorships: author.map {
            [Authorship(author: Author(id: nil, displayName: $0))]
        } ?? [],
        abstractInvertedIndex: nil,
        primaryLocation: Location(
            isOpenAccess: true,
            landingPageURL: publisherURL,
            pdfURL: "https://publisher.example/article.pdf",
            source: Source(displayName: "Example Journal"),
            license: nil,
            version: nil
        ),
        bestOpenAccessLocation: bestPublisherURL.map {
            Location(
                isOpenAccess: true,
                landingPageURL: $0,
                pdfURL: nil,
                source: Source(displayName: "Best Source"),
                license: nil,
                version: nil
            )
        },
        openAccess: OpenAccess(isOpenAccess: true, status: "gold", openAccessURL: nil),
        contentURLs: nil,
        hasFullText: false,
        ids: WorkIDs(pmid: pmid, pmcid: nil),
        locations: [],
        isRetracted: false,
        type: "article",
        language: "en",
        abstractPlain: "Fixture abstract"
    )
}

func makeSnapshot(query: String, works: [Work]) -> SearchHistorySnapshot {
    SearchHistorySnapshot(
        revision: 0,
        displayQuery: query,
        retrievalQuery: query,
        sort: .relevance,
        fromYearEnabled: false,
        fromYear: 2020,
        openAccessOnly: false,
        allWorks: works,
        rankedWorks: works,
        totalCount: works.count,
        currentPage: 1,
        selectedWorkID: works.first?.id,
        lastAIPlan: nil,
        aiReasons: [:],
        aiScores: [:],
        aiEvidenceLevels: [:],
        aiSearchNotice: nil,
        pubMedNotice: nil,
        searchTimingSummary: nil,
        fullTextReviewSummaries: [:],
        articleSummaries: [:],
        currentEvidenceTable: nil,
        currentFieldScanReport: nil
    )
}

func makeRecord(
    id: UUID = UUID(),
    query: String,
    works: [Work],
    date: Date,
    useLedger: UseLedger = UseLedger()
) -> SearchHistoryRecord {
    SearchHistoryRecord(
        schemaVersion: SearchHistoryRecord.currentSchemaVersion,
        id: id,
        displayQuery: query,
        normalizedQuery: SearchQueryIdentity.normalize(query),
        createdAt: date,
        lastSuccessfulSearchAt: date,
        snapshot: makeSnapshot(query: query, works: works),
        useLedger: useLedger
    )
}
