import Foundation
import Testing
@testable import RagBio

@MainActor
@Suite struct SearchHistoryExportTests {
    @Test func URLPriorityUsesCanonicalLowercaseDOI() {
        let work = makeWork(
            doi: "HTTPS://DOI.ORG/10.1000/Example",
            pmid: "999",
            publisherURL: "https://publisher.example/article"
        )

        #expect(
            SearchHistoryURLResolver.url(for: work)?.absoluteString
                == "https://doi.org/10.1000/example"
        )
    }

    @Test func URLPriorityFallsBackToPubMed() {
        let work = makeWork(doi: nil, pmid: "123")

        #expect(
            SearchHistoryURLResolver.url(for: work)?.absoluteString
                == "https://pubmed.ncbi.nlm.nih.gov/123/"
        )
    }

    @Test func URLPriorityFallsBackToBestThenPrimaryLandingPage() {
        let best = makeWork(
            doi: nil,
            pmid: nil,
            publisherURL: "https://publisher.example/primary",
            bestPublisherURL: "HTTPS://BEST.EXAMPLE/article"
        )
        let primary = makeWork(doi: nil, pmid: nil)

        #expect(
            SearchHistoryURLResolver.url(for: best)?.absoluteString
                == "https://best.example/article"
        )
        #expect(
            SearchHistoryURLResolver.url(for: primary)?.absoluteString
                == "https://publisher.example/article"
        )
    }

    @Test func URLPriorityFallsBackToCanonicalOpenAlexPage() {
        let work = makeWork(
            id: "https://api.openalex.org/works/w123",
            doi: nil,
            pmid: nil,
            publisherURL: nil
        )

        #expect(
            SearchHistoryURLResolver.url(for: work)?.absoluteString
                == "https://openalex.org/W123"
        )
    }

    @Test func malformedIdentifiersAndNonHTTPURLsAreRejected() {
        let work = makeWork(
            id: "not-an-openalex-id",
            doi: "not a doi",
            pmid: "PMID-123",
            publisherURL: "ftp://publisher.example/article"
        )

        #expect(SearchHistoryURLResolver.url(for: work) == nil)
    }

    @Test func malformedLandingPageWithWhitespaceIsRejected() {
        let work = makeWork(
            id: "not-an-openalex-id",
            doi: nil,
            pmid: nil,
            publisherURL: "https://publisher.example/bad path"
        )

        #expect(SearchHistoryURLResolver.url(for: work) == nil)
    }

    @Test(arguments: [
        "https://publisher.example/paper.pdf",
        "https://publisher.example/paper.PDF?download=1",
        "https://publisher.example/paper.pdf#page=2",
        "https://doi.org/10.1000/example",
        "https://api.openalex.org/works/W1"
    ])
    func PDFAndIdentifierLandingPagesAreRejected(landingPage: String) {
        let work = makeWork(
            id: "https://openalex.org/W9",
            doi: nil,
            pmid: nil,
            publisherURL: landingPage
        )

        #expect(
            SearchHistoryURLResolver.url(for: work)?.absoluteString
                == "https://openalex.org/W9"
        )
    }

    @Test func exportDeduplicatesNormalizedURLsOnlyWithinEachChunk() {
        var olderLedger = UseLedger()
        olderLedger.mark(makeWork(
            id: "https://openalex.org/W1",
            doi: nil,
            pmid: nil,
            title: "First",
            publisherURL: "HTTPS://PUBLISHER.EXAMPLE/article"
        ))
        olderLedger.mark(makeWork(
            id: "https://openalex.org/W2",
            doi: nil,
            pmid: nil,
            title: "Second",
            publisherURL: "https://publisher.example/article"
        ))
        var newerLedger = UseLedger()
        newerLedger.mark(makeWork(
            id: "https://openalex.org/W3",
            doi: nil,
            pmid: nil,
            title: "Third",
            publisherURL: "https://publisher.example/article"
        ))
        let older = makeRecord(
            query: "older",
            works: [],
            date: Date(timeIntervalSince1970: 60),
            useLedger: olderLedger
        )
        let newer = makeRecord(
            query: "newer",
            works: [],
            date: Date(timeIntervalSince1970: 120),
            useLedger: newerLedger
        )

        let document = SearchHistoryExportBuilder.make(
            records: [newer, older],
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(document.urlCount == 2)
        #expect(
            document.text.components(
                separatedBy: "https://publisher.example/article"
            ).count - 1 == 2
        )
    }

    @Test func exportSkipsMissingURLsAndRendersExactOldestFirstText() {
        var olderLedger = UseLedger()
        olderLedger.mark(makeWork(doi: "10.1000/OLDER"))
        olderLedger.mark(makeWork(
            id: "",
            doi: nil,
            pmid: nil,
            title: "No URL",
            publisherURL: nil
        ))
        var newerLedger = UseLedger()
        newerLedger.mark(makeWork(doi: nil, pmid: "456"))
        let older = makeRecord(
            query: "older query",
            works: [],
            date: Date(timeIntervalSince1970: 0),
            useLedger: olderLedger
        )
        let newer = makeRecord(
            query: "newer query",
            works: [],
            date: Date(timeIntervalSince1970: 60),
            useLedger: newerLedger
        )

        let document = SearchHistoryExportBuilder.make(
            records: [newer, older],
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        #expect(document.urlCount == 2)
        #expect(document.skippedPaperCount == 1)
        #expect(document.text == """
            ------
            Query: older query
            Search Time: 1970-01-01 00:00
            https://doi.org/10.1000/older
            ------
            Query: newer query
            Search Time: 1970-01-01 00:01
            https://pubmed.ncbi.nlm.nih.gov/456/
            ------

            """)
    }

    @Test func storeLoadsOnlySelectedAuthoritativeRecordsWithUse() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        var ledger = UseLedger()
        ledger.mark(makeWork())
        let eligible = makeRecord(
            query: "eligible",
            works: [],
            date: Date(timeIntervalSince1970: 1),
            useLedger: ledger
        )
        let empty = makeRecord(
            query: "empty",
            works: [],
            date: Date(timeIntervalSince1970: 2)
        )
        _ = try await historyStore.save(eligible)
        _ = try await historyStore.save(empty)
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)

        let document = try await store.loadExportRecords(ids: [eligible.id, empty.id])

        #expect(document.urlCount == 1)
        #expect(document.text.contains("Query: eligible"))
        #expect(!document.text.contains("Query: empty"))
    }

    @Test func cancelledRecordLoadDoesNotReturnADocument() async throws {
        let root = try makeTemporaryDirectory()
        let historyStore = SearchHistoryStore(
            root: root.appendingPathComponent("SearchHistory"),
            legacyRoot: root.appendingPathComponent("SearchSession")
        )
        try await historyStore.bootstrap()
        let store = SearchStore(historyStore: historyStore, restoreOnInit: false)
        let task = Task {
            try await store.loadExportRecords(ids: [UUID()])
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("A cancelled export load returned a document")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test func candidatesAreEligibleNewestFirstAndCurrentDefaultsSelected() {
        let current = summary(query: "current", date: 2, useCount: 1)
        let newest = summary(query: "newest", date: 3, useCount: 2)
        let empty = summary(query: "empty", date: 4, useCount: 0)
        let candidates = SearchHistoryExportSelection.candidates(
            [current, empty, newest]
        )

        #expect(candidates.map(\.id) == [newest.id, current.id])
        #expect(
            SearchHistoryExportSelection.initialIDs(
                candidates: candidates,
                currentHistoryID: current.id
            ) == [current.id]
        )
    }

    @Test func completionStatusMatchesApprovedEnglishText() {
        let store = SearchStore(restoreOnInit: false)
        let document = SearchHistoryExportDocument(
            text: "",
            urlCount: 12,
            skippedPaperCount: 2
        )

        store.presentExportStatus(document)

        #expect(
            store.exportMessage
                == "Exported 12 URLs. Skipped 2 papers without a usable URL."
        )
    }

    private func summary(
        query: String,
        date: TimeInterval,
        useCount: Int
    ) -> SearchHistorySummary {
        SearchHistorySummary(
            id: UUID(),
            displayQuery: query,
            normalizedQuery: SearchQueryIdentity.normalize(query),
            createdAt: Date(timeIntervalSince1970: date),
            lastSuccessfulSearchAt: Date(timeIntervalSince1970: date),
            paperCount: 1,
            useCount: useCount
        )
    }
}
