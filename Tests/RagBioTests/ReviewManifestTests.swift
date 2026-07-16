import Foundation
import Testing
@testable import RagBio

@Suite struct ReviewManifestTests {
    @Test func manifestAndManualExportShareIncludedURLs() {
        var ledger = UseLedger()
        ledger.mark(makeWork(id: "https://openalex.org/W1", doi: "10.1000/ONE"))
        ledger.mark(makeWork(id: "https://openalex.org/W2", doi: nil, pmid: "22"))
        ledger.mark(makeWork(
            id: "https://openalex.org/W3",
            doi: nil,
            pmid: nil,
            publisherURL: "https://publisher.example/article"
        ))
        let record = makeRecord(
            query: "review query",
            works: [],
            date: Date(timeIntervalSince1970: 10),
            useLedger: ledger
        )

        let manifest = ReviewInputManifest.make(
            record: record,
            jobID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            manifestID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let export = SearchHistoryExportBuilder.make(records: [record])

        #expect(manifest.usableURLCount == 3)
        for paper in manifest.includedPapers {
            #expect(export.text.contains(paper.sourceURL!.absoluteString))
        }
    }

    @Test func manifestPreservesUseOrderAndRecordsDuplicateAndMissingURLs() {
        var ledger = UseLedger()
        ledger.mark(makeWork(
            id: "https://openalex.org/W1",
            doi: nil,
            pmid: nil,
            title: "First report",
            publisherURL: "https://publisher.example/same"
        ))
        ledger.mark(makeWork(
            id: "https://openalex.org/W2",
            doi: nil,
            pmid: nil,
            title: "Second report",
            publisherURL: "https://publisher.example/same"
        ))
        ledger.mark(makeWork(
            id: "",
            doi: nil,
            pmid: nil,
            title: "No source",
            publisherURL: nil
        ))
        let record = makeRecord(
            query: "duplicates",
            works: [],
            date: Date(timeIntervalSince1970: 10),
            useLedger: ledger
        )

        let manifest = ReviewInputManifest.make(record: record, jobID: UUID())

        #expect(manifest.papers.map(\.order) == [1, 2, 3])
        #expect(manifest.papers.map(\.disposition) == [.included, .duplicateURL, .missingURL])
        #expect(manifest.papers[1].duplicateOfOrder == 1)
        #expect(manifest.usableURLCount == 1)
        #expect(manifest.duplicateURLCount == 1)
        #expect(manifest.missingURLCount == 1)
    }

    @Test func manifestDoesNotChangeWhenUseLedgerChangesLater() {
        var ledger = UseLedger()
        let first = makeWork(id: "https://openalex.org/W1", doi: "10.1000/ONE")
        let second = makeWork(id: "https://openalex.org/W2", doi: "10.1000/TWO")
        ledger.mark(first)
        var record = makeRecord(
            query: "immutable",
            works: [],
            date: Date(timeIntervalSince1970: 10),
            useLedger: ledger
        )
        let manifest = ReviewInputManifest.make(record: record, jobID: UUID())

        record.useLedger.mark(second)
        record.useLedger.remove(first)

        #expect(manifest.papers.count == 1)
        #expect(manifest.papers.first?.title == first.title)
        #expect(manifest.includedPapers.first?.sourceURL?.absoluteString == "https://doi.org/10.1000/one")
    }
}
