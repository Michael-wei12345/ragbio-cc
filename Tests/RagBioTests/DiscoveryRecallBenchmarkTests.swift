import Foundation
import Testing
@testable import RagBio

@Suite(.serialized)
struct DiscoveryRecallBenchmarkTests {
    @Test
    func liveTenReviewBenchmarkMeasuresBlindMultiSourceRecallBeforeAITriage() async throws {
        guard ProcessInfo.processInfo.environment["RAGBIO_RUN_DISCOVERY_BENCHMARK"] == "1" else {
            return
        }

        let requestedReviewID = ProcessInfo.processInfo.environment[
            "RAGBIO_SR_BENCHMARK_REVIEW_ID"
        ]
        let manifests = try SRBenchmarkFixtureLoader.loadAll().filter {
            requestedReviewID == nil || $0.id == requestedReviewID
        }
        #expect(!manifests.isEmpty)
        var totalGold = 0
        var totalFused = 0
        var totalPreTriage = 0
        for manifest in manifests {
            let hits = await retrieveBlindCandidates(for: manifest)
            let eligibleHits = hits.filter {
                isEligibleAtReviewCutoff($0.work, manifest: manifest)
            }
            let fused = CandidateFusion.fuse(eligibleHits)
            let preTriage = CandidatePoolSelector.select(
                from: fused,
                decisions: [:],
                profile: manifest.question.profile,
                limit: min(480, fused.count),
                unclearReserve: min(480, fused.count),
                backgroundReserve: min(20, fused.count)
            )
            try SRBenchmarkCandidateCache.save(preTriage, reviewID: manifest.id)
            let fusedMetrics = SRBenchmarkEvaluator.evaluate(
                manifest: manifest,
                rankedRecords: fused.map { SRBenchmarkRecord(work: $0.work) }
            )
            let preTriageMetrics = SRBenchmarkEvaluator.evaluate(
                manifest: manifest,
                rankedRecords: preTriage.map { SRBenchmarkRecord(work: $0) }
            )
            let sourceSummary = DiscoverySource.allCases.map { source -> String in
                let sourceWorks = eligibleHits.filter { $0.source == source }.map(\.work)
                let sourceMetrics = SRBenchmarkEvaluator.evaluate(
                    manifest: manifest,
                    rankedRecords: sourceWorks.map { SRBenchmarkRecord(work: $0) }
                )
                return "\(source.rawValue)=\(sourceMetrics.foundFamilyIDs.count)"
            }.joined(separator: ",")
            let misses = Set(manifest.goldStudyFamilies.map(\.id))
                .subtracting(preTriageMetrics.foundFamilyIDs)
                .sorted()
                .joined(separator: ",")
            let goldCount = fusedMetrics.goldFamilyCount
            let fusedCount = fusedMetrics.foundFamilyIDs.count
            let preTriageCount = preTriageMetrics.foundFamilyIDs.count
            let candidateCount = fused.count
            totalGold += goldCount
            totalFused += fusedCount
            totalPreTriage += preTriageCount
            let line = "SRBENCH review=\(manifest.id) gold=\(goldCount) "
                + "fused=\(fusedCount) pre480=\(preTriageCount) "
                + "candidates=\(candidateCount) sources=[\(sourceSummary)] "
                + "misses=[\(misses)]"
            print(line)

            #expect(fusedMetrics.familyRecall >= 0.80)
            #expect(preTriageMetrics.familyRecall >= 0.80)
        }
        let fusedRecall = Double(totalFused) / Double(totalGold)
        let preTriageRecall = Double(totalPreTriage) / Double(totalGold)
        print(
            "SRBENCH-TOTAL reviews=\(manifests.count) gold=\(totalGold) "
                + "fused=\(totalFused) pre480=\(totalPreTriage) "
                + "fusedRecall=\(fusedRecall) pre480Recall=\(preTriageRecall)"
        )
        #expect(fusedRecall >= 0.95)
        #expect(preTriageRecall >= 0.95)
    }

    @Test
    func liveTenReviewBenchmarkMeasuresAIRecallAt180UsingFrozenCandidates() async throws {
        guard ProcessInfo.processInfo.environment["RAGBIO_RUN_AI_BENCHMARK"] == "1" else {
            return
        }
        let configuration = try #require(
            configuredAppProvider(),
            "Configure an AI provider in RagBio before running the AI benchmark."
        )
        let planner = AIQueryPlanner()
        let requestedReviewID = ProcessInfo.processInfo.environment[
            "RAGBIO_SR_BENCHMARK_REVIEW_ID"
        ]
        let manifests = try SRBenchmarkFixtureLoader.loadAll().filter {
            requestedReviewID == nil || $0.id == requestedReviewID
        }
        #expect(!manifests.isEmpty)

        var totalAvailable = 0
        var totalSelected = 0
        for manifest in manifests {
            let candidates = try SRBenchmarkCandidateCache.load(reviewID: manifest.id)
            let availableMetrics = SRBenchmarkEvaluator.evaluate(
                manifest: manifest,
                rankedRecords: candidates.map { SRBenchmarkRecord(work: $0) }
            )
            let decisions = await triage(
                candidates,
                description: manifest.question.naturalLanguageInput,
                profile: manifest.question.profile,
                planner: planner,
                configuration: configuration
            )
            let fused = candidates.enumerated().map {
                FusedCandidate(
                    work: $0.element,
                    discoveryScore: 1.0 / Double($0.offset + 1),
                    sources: [.pubMed],
                    firstSeenOrder: $0.offset
                )
            }
            let selected = CandidatePoolSelector.select(
                from: fused,
                decisions: decisions,
                profile: manifest.question.profile,
                limit: min(180, fused.count)
            )
            try SRBenchmarkCandidateCache.save(
                selected,
                reviewID: manifest.id,
                stage: "ai180"
            )
            let metrics = SRBenchmarkEvaluator.evaluate(
                manifest: manifest,
                rankedRecords: selected.map { SRBenchmarkRecord(work: $0) }
            )
            let sourceMisses = Set(manifest.goldStudyFamilies.map(\.id))
                .subtracting(availableMetrics.foundFamilyIDs)
                .sorted()
                .joined(separator: ",")
            let triageMisses = availableMetrics.foundFamilyIDs
                .subtracting(metrics.foundFamilyIDs)
                .sorted()
                .joined(separator: ",")
            let found = metrics.foundFamilyIDs.count
            let available = availableMetrics.foundFamilyIDs.count
            totalAvailable += available
            totalSelected += found
            print(
                "SRBENCH-AI review=\(manifest.id) model=\(configuration.model) "
                    + "available=\(available) at180=\(found) "
                    + "sourceMisses=[\(sourceMisses)] triageMisses=[\(triageMisses)]"
            )
            #expect(available == 0 || Double(found) / Double(available) >= 0.80)
        }
        let recall = Double(totalSelected) / Double(totalAvailable)
        print(
            "SRBENCH-AI-TOTAL reviews=\(manifests.count) available=\(totalAvailable) "
                + "at180=\(totalSelected) recall=\(recall)"
        )
        #expect(recall >= 0.95)
    }

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

    private func retrieveBlindCandidates(
        for manifest: SRBenchmarkManifest
    ) async -> [SearchCandidateHit] {
        let openAlex = OpenAlexClient()
        let pubMed = PubMedClient()
        let clinicalTrials = ClinicalTrialsClient()
        let openAlexKey = ProcessInfo.processInfo.environment["OPENALEX_API_KEY"]

        return await withTaskGroup(of: [SearchCandidateHit].self) { group in
            for (lane, query) in manifest.openAlexQueries.enumerated() {
                group.addTask {
                    guard let response = try? await openAlex.search(
                        query: query,
                        sort: .relevance,
                        fromYear: nil,
                        openAccessOnly: false,
                        apiKey: openAlexKey,
                        page: 1,
                        perPage: 200,
                        timeout: 30
                    ) else {
                        return []
                    }
                    return response.results.enumerated().map {
                        SearchCandidateHit(
                            work: $0.element,
                            source: .openAlex,
                            lane: lane,
                            rank: $0.offset + 1
                        )
                    }
                }
            }
            for (lane, query) in manifest.pubMedQueries.enumerated() {
                group.addTask {
                    guard let works = try? await pubMed.search(
                        query: query,
                        fromYear: nil,
                        maxResults: 500,
                        contactEmail: nil,
                        timeout: 30
                    ) else {
                        return []
                    }
                    return works.enumerated().map {
                        SearchCandidateHit(
                            work: $0.element,
                            source: .pubMed,
                            lane: lane,
                            rank: $0.offset + 1
                        )
                    }
                }
            }
            for (lane, query) in manifest.clinicalTrialsQueries.enumerated() {
                group.addTask {
                    guard let works = try? await clinicalTrials.search(
                        query: query,
                        pageSize: 100,
                        timeout: 30
                    ) else {
                        return []
                    }
                    return works.enumerated().map {
                        SearchCandidateHit(
                            work: $0.element,
                            source: .clinicalTrials,
                            lane: lane,
                            rank: $0.offset + 1
                        )
                    }
                }
            }

            var hits: [SearchCandidateHit] = []
            for await result in group {
                hits += result
            }
            return hits
        }
    }

    private func isEligibleAtReviewCutoff(
        _ work: Work,
        manifest: SRBenchmarkManifest
    ) -> Bool {
        let identity = SRBenchmarkIdentity(work: work)
        if manifest.goldStudyFamilies.contains(where: { family in
            family.reports.contains { $0.identity.matches(identity) }
        }) {
            return true
        }
        guard let date = work.publicationDate else { return true }
        return date <= manifest.review.searchCutoff
    }

    private func configuredAppProvider() -> AIProviderConfiguration? {
        let defaults = UserDefaults(suiteName: "com.local.RagBio") ?? .standard
        let provider = defaults.string(forKey: SettingsKeys.activeAIProvider)
            .flatMap(AIProvider.init(rawValue:))
            ?? .deepSeek
        let configuration = AIProviderConfiguration(
            provider: provider,
            apiKey: CredentialStore.string(for: provider.credentialKey),
            model: defaults.string(forKey: SettingsKeys.aiModel(provider))
                ?? provider.defaultModel,
            baseURL: defaults.string(forKey: SettingsKeys.aiBaseURL(provider))
                ?? provider.defaultBaseURL
        )
        return configuration.isConfigured ? configuration : nil
    }

    private func triage(
        _ works: [Work],
        description: String,
        profile: ResearchQuestionProfile,
        planner: AIQueryPlanner,
        configuration: AIProviderConfiguration
    ) async -> [Int: AICandidateTriageOutput] {
        let ranges = stride(from: 0, to: works.count, by: 32).map {
            $0..<min($0 + 32, works.count)
        }
        var decisions: [Int: AICandidateTriageOutput] = [:]
        await withTaskGroup(of: (Range<Int>, [AICandidateTriageOutput]?).self) { group in
            var next = 0
            func enqueue(_ range: Range<Int>) {
                let batch = Array(works[range])
                group.addTask {
                    let output = try? await planner.triageCandidateBatch(
                        description: description,
                        profile: profile,
                        works: batch,
                        configuration: configuration
                    )
                    return (range, output)
                }
            }
            while next < min(6, ranges.count) {
                enqueue(ranges[next])
                next += 1
            }
            for await (range, outputs) in group {
                for output in outputs ?? [] {
                    let absolute = range.lowerBound + output.index
                    guard range.contains(absolute) else { continue }
                    decisions[absolute] = output.withIndex(absolute)
                }
                if next < ranges.count {
                    enqueue(ranges[next])
                    next += 1
                }
            }
        }
        return decisions
    }
}
