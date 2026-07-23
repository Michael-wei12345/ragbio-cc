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
            title: "Adjuvant paclitaxel and trastuzumab for node-negative HER2-positive breast cancer",
            isOpenAccess: true,
            abstract: "OpenAlex abstract."
        )
        let aptPubMed = makeWork(
            id: "https://pubmed.ncbi.nlm.nih.gov/25564897",
            doi: "10.1056/nejmoa1406281",
            pmid: "25564897",
            title: aptOpenAlex.title,
            isOpenAccess: false,
            abstract: "A substantially longer PubMed abstract that should remain available after fusion."
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
        #expect(fused.first?.work.isOpenAccess == true)
        #expect(fused.first?.work.abstractText == aptPubMed.abstractText)
    }

    @Test func conservativeTriageKeepsLikelyUnclearAndBackgroundButDropsOnlyHighConfidenceMismatch() {
        let direct = makeWork(
            id: "direct",
            doi: "10.1000/direct",
            title: "Randomized trastuzumab duration trial in early HER2-positive breast cancer",
            abstract: "Patients were randomized to shorter or one-year adjuvant trastuzumab."
        )
        let secondary = makeWork(
            id: "secondary",
            doi: "10.1000/secondary",
            title: "HER2-positive breast cancer cohort"
        )
        let uncertain = makeWork(
            id: "uncertain",
            doi: "10.1000/uncertain",
            title: "Potentially relevant trial",
            abstract: nil
        )
        let review = makeWork(
            id: "review",
            doi: "10.1000/review",
            title: "Systematic review of adjuvant trastuzumab duration",
            type: "review",
            publicationTypes: ["Systematic Review"]
        )
        let mismatch = makeWork(
            id: "mismatch",
            doi: "10.1000/mismatch",
            title: "Metastatic colorectal cancer chemotherapy"
        )
        let candidates = [direct, secondary, uncertain, review, mismatch].enumerated().map {
            FusedCandidate(
                work: $0.element,
                discoveryScore: 1 - Double($0.offset) * 0.1,
                sources: [.pubMed],
                firstSeenOrder: $0.offset
            )
        }
        let decisions: [Int: AICandidateTriageOutput] = [
            0: .init(index: 0, disposition: .likely, directness: 3, confidence: .high),
            1: .init(index: 1, disposition: .likely, directness: 1, confidence: .medium),
            2: .init(index: 2, disposition: .explicitMismatch, directness: 0, confidence: .high),
            3: .init(index: 3, disposition: .likely, directness: 3, confidence: .high),
            4: .init(index: 4, disposition: .explicitMismatch, directness: 0, confidence: .high)
        ]
        let profile = ResearchQuestionProfile(
            questionType: .intervention,
            population: ["early HER2-positive breast cancer"],
            interventionOrExposure: ["trastuzumab"],
            comparator: ["shorter duration", "one year"],
            outcomes: [],
            context: ["adjuvant"],
            preferredStudyDesigns: ["randomized trial"]
        )

        let selected = CandidatePoolSelector.select(
            from: candidates,
            decisions: decisions,
            profile: profile,
            limit: 4,
            unclearReserve: 1,
            backgroundReserve: 1
        )

        #expect(selected.map(\.id).contains("direct"))
        #expect(selected.map(\.id).contains("secondary"))
        #expect(selected.map(\.id).contains("uncertain"))
        #expect(selected.map(\.id).contains("review"))
        #expect(!selected.map(\.id).contains("mismatch"))
    }

    @Test func cheapDiscoveryPriorityPrefersDirectTrialOverBroadTopicReview() {
        let profile = ResearchQuestionProfile(
            questionType: .intervention,
            population: ["early HER2-positive breast cancer"],
            interventionOrExposure: ["trastuzumab"],
            comparator: ["short duration", "one year"],
            outcomes: ["disease-free survival"],
            context: ["adjuvant"],
            preferredStudyDesigns: ["randomized trial"]
        )
        let direct = makeWork(
            title: "Short versus one-year adjuvant trastuzumab for early HER2-positive breast cancer",
            publicationTypes: ["Randomized Controlled Trial"],
            abstract: "The randomized trial reported disease-free survival."
        )
        let broad = makeWork(
            title: "General awareness and treatment of breast cancer",
            type: "review",
            publicationTypes: ["Review"],
            abstract: "A broad review of breast cancer prevention and treatment."
        )

        #expect(
            CandidateDiscoveryScorer.score(work: direct, profile: profile)
                > CandidateDiscoveryScorer.score(work: broad, profile: profile)
        )
    }

    @Test func deepDatabaseHitSurvivesBroadDiscoveryThroughEligibilityPriority() {
        let profile = ResearchQuestionProfile(
            questionType: .intervention,
            population: ["early HER2-positive breast cancer"],
            interventionOrExposure: ["trastuzumab"],
            comparator: ["short duration", "one year"],
            outcomes: ["disease-free survival"],
            context: ["adjuvant"],
            preferredStudyDesigns: ["randomized trial"]
        )
        var candidates = (0..<1_300).map { index in
            FusedCandidate(
                work: makeWork(
                    id: "broad-\(index)",
                    doi: "10.1000/broad-\(index)",
                    title: "General oncology article \(index)",
                    abstract: "Background information about cancer care."
                ),
                discoveryScore: 10 - Double(index) / 100,
                sources: [.pubMed],
                firstSeenOrder: index
            )
        }
        let target = makeWork(
            id: "deep-target",
            doi: "10.1000/deep-target",
            title: "Short versus one-year adjuvant trastuzumab in early HER2-positive breast cancer",
            publicationTypes: ["Randomized Controlled Trial"],
            abstract: "A randomized trial reporting disease-free survival after shorter therapy."
        )
        candidates.append(
            FusedCandidate(
                work: target,
                discoveryScore: 0.001,
                sources: [.pubMed],
                firstSeenOrder: 1_300
            )
        )

        let preTriage = CandidatePoolSelector.select(
            from: candidates,
            decisions: [:],
            profile: profile,
            limit: 480,
            unclearReserve: 480,
            backgroundReserve: 0
        )

        #expect(preTriage.contains(where: { $0.id == target.id }))
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
