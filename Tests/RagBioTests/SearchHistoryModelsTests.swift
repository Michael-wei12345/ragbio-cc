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

    @Test func bridgingWorkCoalescesEveryMatchingLedgerEntryWithoutRemovingUnrelatedUse() {
        let doiOnly = makeWork(
            id: "doi-only",
            doi: "10.1000/bridge",
            pmid: nil,
            title: "DOI metadata"
        )
        let pmidOnly = makeWork(
            id: "pmid-only",
            doi: nil,
            pmid: "https://pubmed.ncbi.nlm.nih.gov/987/",
            title: "PMID metadata"
        )
        let unrelated = makeWork(
            id: "unrelated",
            doi: "10.1000/unrelated",
            pmid: nil,
            title: "Unrelated"
        )
        let bridge = makeWork(
            id: "bridge",
            doi: "10.1000/bridge",
            pmid: "https://pubmed.ncbi.nlm.nih.gov/987/",
            title: "Refreshed bridge"
        )
        var ledger = UseLedger()
        ledger.mark(doiOnly, at: Date(timeIntervalSince1970: 2))
        ledger.mark(unrelated, at: Date(timeIntervalSince1970: 3))
        ledger.mark(pmidOnly, at: Date(timeIntervalSince1970: 1))

        ledger.mark(bridge, at: Date(timeIntervalSince1970: 4))

        #expect(ledger.papers.map(\.work.id) == [bridge.id, unrelated.id])
        #expect(ledger.papers[0].selectedAt == Date(timeIntervalSince1970: 1))
        #expect(ledger.papers[0].identity.keys.contains("doi:10.1000/bridge"))
        #expect(ledger.papers[0].identity.keys.contains("pmid:987"))
        #expect(ledger.contains(doiOnly))
        #expect(ledger.contains(pmidOnly))
        #expect(ledger.contains(unrelated))
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

        object["decisionFilter"] = "candidate"
        let candidate = try JSONDecoder().decode(
            SearchHistorySnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(candidate.decisionFilter == .candidate)

        for obsolete in ["maybe", "exclude", "unreviewed", "future-value"] {
            object["decisionFilter"] = obsolete
            let decoded = try JSONDecoder().decode(
                SearchHistorySnapshot.self,
                from: JSONSerialization.data(withJSONObject: object)
            )
            #expect(decoded.decisionFilter == .all)
        }
    }

    @Test func onlyDefiniteNonPrimaryPublicationTypesAreFiltered() {
        #expect(makeWork(type: "review").nonPrimaryPublicationKind == .review)
        #expect(
            makeWork(
                publicationTypes: ["Journal Article", "Meta-Analysis"]
            ).nonPrimaryPublicationKind == .metaAnalysis
        )
        #expect(
            makeWork(
                publicationTypes: ["Review", "Randomized Controlled Trial"]
            ).nonPrimaryPublicationKind == nil
        )
        #expect(makeWork(type: nil).nonPrimaryPublicationKind == nil)
        #expect(makeWork(isRetracted: true).nonPrimaryPublicationKind == .retracted)
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
            ) == .globalEvidenceRanking
        )
    }
}
