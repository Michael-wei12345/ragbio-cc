import Foundation
import Testing
@testable import RagBio

@Suite(.serialized)
struct DiscoveryRecallBenchmarkTests {
    @Test
    func liveHER2DurationReviewKeepsAllKnownTrialFamiliesBeforeAITriage() async throws {
        guard ProcessInfo.processInfo.environment["RAGBIO_RUN_DISCOVERY_BENCHMARK"] == "1" else {
            return
        }

        let queries = [
            """
            ("Breast Neoplasms"[MeSH Terms] OR "breast cancer"[Title/Abstract]) AND \
            (HER2[Title/Abstract] OR ERBB2[Title/Abstract]) AND trastuzumab[Title/Abstract] AND \
            (adjuvant[Title/Abstract] OR early[Title/Abstract])
            """,
            """
            "breast cancer"[Title/Abstract] AND (HER2[Title/Abstract] OR ERBB2[Title/Abstract]) AND \
            trastuzumab[Title/Abstract] AND (duration[Title/Abstract] OR shorter[Title/Abstract] OR \
            weeks[Title/Abstract] OR months[Title/Abstract])
            """,
            """
            "breast cancer"[Title/Abstract] AND trastuzumab[Title/Abstract] AND \
            randomized controlled trial[Publication Type]
            """
        ]
        let client = PubMedClient()
        var hits: [SearchCandidateHit] = []
        for (lane, query) in queries.enumerated() {
            let works = try await client.search(
                query: query,
                fromYear: nil,
                maxResults: 500,
                contactEmail: nil,
                timeout: 30
            )
            hits += works.enumerated().map {
                SearchCandidateHit(
                    work: $0.element,
                    source: .pubMed,
                    lane: lane,
                    rank: $0.offset + 1
                )
            }
        }

        let profile = ResearchQuestionProfile(
            questionType: .intervention,
            population: ["early HER2-positive breast cancer"],
            interventionOrExposure: ["adjuvant trastuzumab"],
            comparator: ["shorter versus one-year duration"],
            outcomes: ["disease-free survival", "overall survival", "cardiac toxicity"],
            context: ["adjuvant"],
            preferredStudyDesigns: ["randomized controlled trial"]
        )
        let fused = CandidateFusion.fuse(hits)
        let preTriage = CandidatePoolSelector.select(
            from: fused,
            decisions: [:],
            profile: profile,
            limit: min(480, fused.count),
            unclearReserve: min(480, fused.count),
            backgroundReserve: 20
        )
        let retainedPMIDs = Set(preTriage.compactMap(\.normalizedPMID))
        let fusedPMIDs = Set(fused.compactMap(\.work.normalizedPMID))
        let goldPMIDs: Set<String> = [
            "26625004", // E2198
            "30219886", // Short-HER
            "29852043", // SOLD
            "25935793", // HORG
            "31178155", // PHARE
            "31178152"  // PERSEPHONE
        ]

        #expect(goldPMIDs.isSubset(of: fusedPMIDs))
        #expect(goldPMIDs.isSubset(of: retainedPMIDs))
    }
}
