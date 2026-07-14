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

    @Test func paperIdentityMatchesDOIOnly() {
        let first = makeWork(id: "", pmid: nil, year: nil)
        let second = makeWork(
            id: "",
            doi: "HTTPS://DOI.ORG/10.1000/EXAMPLE",
            pmid: nil,
            year: nil
        )
        #expect(PaperIdentity(work: first).matches(PaperIdentity(work: second)))
    }

    @Test func paperIdentityMatchesPMIDOnly() {
        let first = makeWork(id: "", doi: nil, year: nil)
        let second = makeWork(id: "", doi: nil, year: nil)
        #expect(PaperIdentity(work: first).matches(PaperIdentity(work: second)))
    }

    @Test func paperIdentityMatchesOpenAlexOnly() {
        let first = makeWork(doi: nil, pmid: nil, year: nil)
        let second = makeWork(doi: nil, pmid: nil, year: nil)
        #expect(PaperIdentity(work: first).matches(PaperIdentity(work: second)))
    }

    @Test func paperIdentityMatchesFallbackOnly() {
        let first = makeWork(id: "", doi: nil, pmid: nil)
        let second = makeWork(id: "", doi: nil, pmid: nil)
        #expect(PaperIdentity(work: first).matches(PaperIdentity(work: second)))
    }

    @Test func conflictingDOIPreventsFallbackMatch() {
        let first = makeWork(id: "", doi: "10.1000/first", pmid: nil)
        let second = makeWork(id: "", doi: "10.1000/second", pmid: nil)
        #expect(!PaperIdentity(work: first).matches(PaperIdentity(work: second)))
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

    @Test func snapshotDecodesMissingAndObsoleteDecisionFiltersAsAll() throws {
        let snapshot = makeSnapshot(query: "gut", works: [makeWork()])
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object.removeValue(forKey: "decisionFilter")
        let missing = try JSONDecoder().decode(
            SearchHistorySnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(missing.decisionFilter == .all)

        for obsolete in ["maybe", "exclude", "unreviewed", "future-value"] {
            object["decisionFilter"] = obsolete
            let decoded = try JSONDecoder().decode(
                SearchHistorySnapshot.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            #expect(decoded.decisionFilter == .all)
        }
    }

    @Test func completedAIStageUsesOnlyUnambiguousTerminalStates() {
        #expect(
            SearchHistoryAIStage.completed(
                coarse: .localReady(candidates: 8),
                evidence: .idle
            ) == .localCandidates
        )
        #expect(
            SearchHistoryAIStage.completed(
                coarse: .failed(message: "coarse failed", candidates: 8),
                evidence: .idle
            ) == .localCandidates
        )
        #expect(
            SearchHistoryAIStage.completed(
                coarse: .completed(candidates: 8, retained: 5),
                evidence: .failed("evidence failed")
            ) == .coarseRanking
        )
        #expect(
            SearchHistoryAIStage.completed(
                coarse: .completed(candidates: 8, retained: 5),
                evidence: .completed(fullText: 2, abstractOnly: 3, retained: 5)
            ) == .evidenceRanking
        )
    }
}
