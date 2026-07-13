import Foundation
import Testing
@testable import RagBio

@Suite struct SearchHistoryModelsTests {
    @Test func queryIdentityNormalizesCaseAndWhitespaceButKeepsPunctuation() {
        #expect(SearchQueryIdentity.normalize("  Gut   Microbiota  ") == "gut microbiota")
        #expect(
            SearchQueryIdentity.normalize("gut microbiota") !=
                SearchQueryIdentity.normalize("gut-microbiota")
        )
    }

    @Test func paperIdentityUsesSharedDOIThenPMIDThenOpenAlexThenFallback() {
        let doiA = makeWork(id: "https://openalex.org/W1")
        let doiB = makeWork(id: "https://openalex.org/W2", doi: "HTTPS://DOI.ORG/10.1000/EXAMPLE")
        #expect(PaperIdentity(work: doiA).matches(PaperIdentity(work: doiB)))

        let fallbackA = makeWork(id: "", doi: nil, pmid: nil)
        let fallbackB = makeWork(id: "", doi: nil, pmid: nil)
        #expect(PaperIdentity(work: fallbackA).matches(PaperIdentity(work: fallbackB)))

        let conflictingDOI = makeWork(id: "", doi: "10.1000/different", pmid: nil)
        #expect(!PaperIdentity(work: doiA).matches(PaperIdentity(work: conflictingDOI)))
    }

    @Test func useLedgerKeepsMissingPaperAndRefreshesMetadataWhenPaperReturns() {
        let old = makeWork(title: "Old title")
        let refreshed = makeWork(title: "Corrected title")
        var ledger = UseLedger()
        ledger.mark(old, at: Date(timeIntervalSince1970: 1))
        ledger.mark(refreshed, at: Date(timeIntervalSince1970: 2))

        #expect(ledger.papers.count == 1)
        #expect(ledger.papers[0].work.title == "Corrected title")
        #expect(ledger.contains(refreshed))
        #expect(ledger.contains(old))
    }

    @Test func onlyExplicitRemovalClearsUse() {
        let work = makeWork()
        var ledger = UseLedger()
        ledger.mark(work, at: Date())
        ledger.remove(work)
        #expect(!ledger.contains(work))
    }
}
