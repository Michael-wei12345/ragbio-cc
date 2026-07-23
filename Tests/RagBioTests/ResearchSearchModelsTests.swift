import Foundation
import Testing
@testable import RagBio

@Suite struct ResearchSearchModelsTests {
    @Test func legacyPlanDecodesWithSingleQueryFallbacks() throws {
        let data = Data(#"{"search_query":"HER2 adjuvant","pubmed_query":"HER2[tiab] AND adjuvant[tiab]","from_year":null,"open_access_only":false,"sort":"relevance","explanation":""}"#.utf8)
        let plan = try JSONDecoder().decode(AISearchPlan.self, from: data)

        #expect(plan.effectiveOpenAlexQueries == ["HER2 adjuvant"])
        #expect(plan.effectivePubMedQueries == ["HER2[tiab] AND adjuvant[tiab]"])
        #expect(plan.effectiveClinicalTrialsQueries == ["HER2 adjuvant"])
        #expect(plan.questionProfile == nil)
    }

    @Test func modernPlanKeepsSourceSpecificQueryLanesAndQuestionType() throws {
        let data = Data(#"{"search_query":"HER2 adjuvant","from_year":null,"open_access_only":false,"sort":"relevance","explanation":"","question_profile":{"question_type":"intervention","population":["early HER2-positive breast cancer"],"intervention_or_exposure":["trastuzumab"],"comparator":[],"outcomes":["disease-free survival"],"context":["adjuvant"],"preferred_study_designs":["randomized trial","cohort"]},"openalex_queries":["HER2 adjuvant trastuzumab","HER2 adjuvant randomized trial"],"pubmed_queries":["HER2[tiab] AND adjuvant[tiab]"],"clinical_trials_queries":["HER2 breast cancer trastuzumab"]}"#.utf8)
        let plan = try JSONDecoder().decode(AISearchPlan.self, from: data)

        #expect(plan.questionProfile?.questionType == .intervention)
        #expect(plan.effectiveOpenAlexQueries.count == 2)
        #expect(plan.effectivePubMedQueries.first?.contains("[tiab]") == true)
        #expect(plan.effectiveClinicalTrialsQueries == ["HER2 breast cancer trastuzumab"])
    }

    @Test func candidateFusionDeduplicatesAndRewardsIndependentSources() {
        let aptOpenAlex = makeWork(
            id: "https://openalex.org/W1",
            doi: "https://doi.org/10.1056/NEJMoa1406281",
            pmid: nil,
            title: "Adjuvant paclitaxel and trastuzumab for node-negative HER2-positive breast cancer"
        )
        let aptPubMed = makeWork(
            id: "https://pubmed.ncbi.nlm.nih.gov/25564897",
            doi: "10.1056/nejmoa1406281",
            pmid: "25564897",
            title: aptOpenAlex.title
        )
        let review = makeWork(
            id: "https://openalex.org/W2",
            doi: "10.1000/review",
            pmid: nil,
            title: "HER2-positive breast cancer review"
        )
        let fused = CandidateFusion.fuse([
            SearchCandidateHit(work: aptOpenAlex, source: .openAlex, lane: 0, rank: 3),
            SearchCandidateHit(work: review, source: .openAlex, lane: 0, rank: 1),
            SearchCandidateHit(work: aptPubMed, source: .pubMed, lane: 0, rank: 2)
        ])

        #expect(fused.count == 2)
        #expect(fused.first?.work.title == aptOpenAlex.title)
        #expect(fused.first?.sources == [.openAlex, .pubMed])
    }

    @Test func coreMismatchFallsBelowThresholdButUnknownDoesNotMeanNo() {
        let matched = card(population: .match, intervention: .match, role: .primary)
        let mismatch = card(population: .mismatch, intervention: .match, role: .primary)
        let unclear = card(population: .unclear, intervention: .unclear, role: .unclear)

        #expect(EvidenceUsefulnessScorer.score(mismatch) == 4)
        #expect(EvidenceUsefulnessScorer.score(matched) > EvidenceUsefulnessScorer.score(unclear))
        #expect(EvidenceUsefulnessScorer.score(unclear) >= 5)
    }

    @Test func studyFamilyUsesRegistryIdentifierBeforeAcronym() {
        let work = makeWork(
            id: "https://clinicaltrials.gov/study/NCT00542451",
            title: "APHINITY trial NCT00542451"
        )
        #expect(StudyFamilyIdentifier.identify(work: work) == "registry:NCT00542451")
    }

    @Test func abstractSectionHeadingsAreNotTreatedAsStudyAcronyms() {
        let work = makeWork(
            title: "Child gastrointestinal disease and depression",
            author: nil
        )
        #expect(
            StudyFamilyIdentifier.identify(
                work: work,
                evidenceText: "BACKGROUND Depression is common. OBJECTIVE Estimate prevalence."
            ) == nil
        )
    }

    @Test func passageSelectionKeepsRelevantEvidenceFromDifferentSections() {
        let paragraphs = [
            FullTextParagraph(id: "m", section: "Methods", text: "HER2 patients randomized to trastuzumab or control.", ordinal: 1, page: 2),
            FullTextParagraph(id: "r", section: "Results", text: "HER2 trastuzumab improved disease-free survival.", ordinal: 2, page: 5),
            FullTextParagraph(id: "d", section: "Discussion", text: "HER2 trastuzumab findings support adjuvant treatment.", ordinal: 3, page: 8),
            FullTextParagraph(id: "r2", section: "Results", text: "HER2 trastuzumab secondary analysis.", ordinal: 4, page: 6)
        ]
        let hits = HybridRetriever.search(
            query: "HER2 trastuzumab adjuvant disease-free survival",
            paragraphs: paragraphs,
            limit: 3
        )

        #expect(hits.count == 3)
        #expect(Set(hits.map { $0.paragraph.section }).count == 3)
    }

    @Test func her2BenchmarkPrioritizesPrimaryReportsAndFiltersHardMismatch() {
        let primary = card(
            population: .match,
            intervention: .match,
            role: .primary,
            outcome: .match,
            context: .match,
            dataRich: true
        )
        let followUp = card(
            population: .match,
            intervention: .match,
            role: .followUp,
            outcome: .match,
            context: .match,
            dataRich: true
        )
        let background = card(
            population: .match,
            intervention: .partial,
            role: .background,
            outcome: .unclear,
            context: .partial
        )
        let hardNegative = card(
            population: .mismatch,
            intervention: .mismatch,
            role: .primary
        )

        let scores = [primary, followUp, background, hardNegative]
            .map(EvidenceUsefulnessScorer.score)
        #expect(scores[0] > scores[2])
        #expect(scores[1] > scores[2])
        #expect(scores[3] < 5)
    }

    private func card(
        population: EvidenceMatch,
        intervention: EvidenceMatch,
        role: EvidenceRole,
        outcome: EvidenceMatch = .unclear,
        context: EvidenceMatch = .unclear,
        dataRich: Bool = false
    ) -> StructuredEvidenceCard {
        StructuredEvidenceCard(
            workID: UUID().uuidString,
            population: population,
            interventionOrExposure: intervention,
            comparator: .unclear,
            outcome: outcome,
            context: context,
            role: role,
            reportsEffectEstimate: dataRich,
            reportsSampleSize: dataRich,
            hasComparatorGroup: dataRich,
            reportsFollowUp: dataRich,
            uniqueContribution: role == .followUp,
            confidence: .medium,
            studyFamilyID: nil,
            evidenceBasis: "abstract"
        )
    }
}
