import Foundation
import Testing
@testable import RagBio

@Suite(.serialized)
struct SRGlobalRankingBenchmarkTests {
    @Test
    func replayFrozenFinalDiagnosticsThroughCurrentSafetyRules() throws {
        guard ProcessInfo.processInfo.environment["RAGBIO_REPLAY_GLOBAL_BENCHMARK"] == "1" else {
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
        var totalVisible = 0
        var totalAvailable = 0
        var totalVisibleAvailable = 0
        for manifest in manifests {
            let snapshot = try SRBenchmarkCandidateCache.loadJSON(
                [SRBenchmarkRankedDiagnostic].self,
                reviewID: manifest.id,
                stage: "final-diagnostic"
            )
            let cards = snapshot.map(\.card)
            let adjusted = SearchStore.safetyAdjustedGlobalScores(
                modelScores: Dictionary(uniqueKeysWithValues: snapshot.indices.map {
                    ($0, snapshot[$0].score)
                }),
                cards: cards
            )
            let ranked = SearchStore.globallyRankedIndices(
                scores: adjusted,
                candidateCount: snapshot.count,
                minimumScore: 0
            )
            let records = ranked.map {
                SRBenchmarkRecord(
                    work: snapshot[$0].work,
                    score: adjusted[$0]
                )
            }
            let metrics = SRBenchmarkEvaluator.evaluate(
                manifest: manifest,
                rankedRecords: records,
                visibleScoreThreshold: 5
            )
            let availableFamilyIDs = SRBenchmarkEvaluator.matchedFamilyIDs(
                records: snapshot.map { SRBenchmarkRecord(work: $0.work) },
                families: manifest.goldStudyFamilies
            )
            let visibleFamilyIDs = SRBenchmarkEvaluator.matchedFamilyIDs(
                records: records.filter { ($0.score ?? -1) >= 5 },
                families: manifest.goldStudyFamilies
            )
            let visibleAvailable = visibleFamilyIDs.intersection(availableFamilyIDs).count
            let thresholdRetention = availableFamilyIDs.isEmpty
                ? 1
                : Double(visibleAvailable) / Double(availableFamilyIDs.count)
            totalGold += metrics.goldFamilyCount
            totalVisible += visibleFamilyIDs.count
            totalAvailable += availableFamilyIDs.count
            totalVisibleAvailable += visibleAvailable
            print(
                "SRBENCH-REPLAY review=\(manifest.id) "
                    + "recall20=\(format(metrics.recallAt20)) "
                    + "recall50=\(format(metrics.recallAt50)) "
                    + "thresholdRecall=\(format(metrics.thresholdedFamilyRecall ?? 0)) "
                    + "thresholdRetention=\(format(thresholdRetention))"
            )
            #expect(thresholdRetention >= 0.95)
            #expect(metrics.criticalFamiliesBelowThreshold.isEmpty)
        }
        let thresholdRecall = Double(totalVisible) / Double(totalGold)
        let thresholdRetention = Double(totalVisibleAvailable) / Double(totalAvailable)
        #expect(thresholdRetention >= 0.95)
        if requestedReviewID == nil {
            #expect(thresholdRecall >= 0.95)
        }
    }

    @Test
    func liveTenReviewBenchmarkMeasuresFinalGlobalRanking() async throws {
        guard ProcessInfo.processInfo.environment["RAGBIO_RUN_GLOBAL_BENCHMARK"] == "1" else {
            return
        }
        let configuration = try #require(
            configuredAppProvider(),
            "Configure an AI provider in RagBio before running the global benchmark."
        )
        let requestedReviewID = ProcessInfo.processInfo.environment[
            "RAGBIO_SR_BENCHMARK_REVIEW_ID"
        ]
        let manifests = try SRBenchmarkFixtureLoader.loadAll().filter {
            requestedReviewID == nil || $0.id == requestedReviewID
        }
        #expect(!manifests.isEmpty)

        var totalGold = 0
        var totalThresholded = 0.0
        var totalAvailable = 0
        var totalVisibleAvailable = 0
        for manifest in manifests {
            let candidates = try SRBenchmarkCandidateCache.load(
                reviewID: manifest.id,
                stage: "ai180"
            )
            let availableFamilyIDs = SRBenchmarkEvaluator.matchedFamilyIDs(
                records: candidates.map { SRBenchmarkRecord(work: $0) },
                families: manifest.goldStudyFamilies
            )
            let (cards, fullTextCount) = await evidenceCards(
                candidates: candidates,
                manifest: manifest,
                configuration: configuration
            )
            let planner = AIQueryPlanner()
            var outputs = try await planner.calibrateGlobalScores(
                description: manifest.question.naturalLanguageInput,
                profile: manifest.question.profile,
                cards: cards,
                works: candidates,
                configuration: configuration
            )
            let returned = Set(outputs.map(\.index))
            let missing = candidates.indices.filter { !returned.contains($0) }
            if !missing.isEmpty {
                let retry = try await planner.calibrateGlobalScores(
                    description: manifest.question.naturalLanguageInput,
                    profile: manifest.question.profile,
                    cards: missing.map { cards[$0] },
                    works: missing.map { candidates[$0] },
                    configuration: configuration
                )
                outputs += retry.compactMap { output in
                    guard missing.indices.contains(output.index) else { return nil }
                    return output.withIndex(missing[output.index])
                }
            }
            let modelScores = try SearchStore.validatedGlobalScores(
                outputs,
                candidateCount: candidates.count
            )
            let scores = SearchStore.safetyAdjustedGlobalScores(
                modelScores: modelScores,
                cards: cards
            )
            let rankedIndices = SearchStore.globallyRankedIndices(
                scores: scores,
                candidateCount: candidates.count,
                minimumScore: 0
            )
            let records = rankedIndices.map { index in
                SRBenchmarkRecord(
                    work: candidates[index],
                    score: scores[index]
                )
            }
            try SRBenchmarkCandidateCache.saveJSON(
                rankedIndices.enumerated().map { offset, index in
                    SRBenchmarkRankedDiagnostic(
                        rank: offset + 1,
                        score: scores[index] ?? 0,
                        work: candidates[index],
                        card: cards[index]
                    )
                },
                reviewID: manifest.id,
                stage: "final-diagnostic"
            )
            let metrics = SRBenchmarkEvaluator.evaluate(
                manifest: manifest,
                rankedRecords: records,
                visibleScoreThreshold: 5
            )
            let belowThreshold = metrics.criticalFamiliesBelowThreshold
                .sorted()
                .joined(separator: ",")
            let thresholdRecall = metrics.thresholdedFamilyRecall ?? 0
            let visibleFamilyIDs = SRBenchmarkEvaluator.matchedFamilyIDs(
                records: records.filter { ($0.score ?? -1) >= 5 },
                families: manifest.goldStudyFamilies
            )
            let visibleAvailable = visibleFamilyIDs.intersection(availableFamilyIDs).count
            let thresholdRetention = availableFamilyIDs.isEmpty
                ? 1
                : Double(visibleAvailable) / Double(availableFamilyIDs.count)
            totalGold += metrics.goldFamilyCount
            totalThresholded += thresholdRecall * Double(metrics.goldFamilyCount)
            totalAvailable += availableFamilyIDs.count
            totalVisibleAvailable += visibleAvailable
            let placements = manifest.goldStudyFamilies.map { family in
                let placement = records.enumerated().first { _, record in
                    family.reports.contains {
                        $0.identity.matches(record.identity)
                    }
                }
                guard let placement else {
                    return "\(family.id)=missing"
                }
                return "\(family.id)=#\(placement.offset + 1):\(placement.element.score ?? -1)"
            }
            .joined(separator: ",")
            print(
                "SRBENCH-GLOBAL review=\(manifest.id) model=\(configuration.model) "
                    + "gold=\(metrics.goldFamilyCount) fulltext=\(fullTextCount) "
                    + "recall20=\(format(metrics.recallAt20)) "
                    + "recall50=\(format(metrics.recallAt50)) "
                    + "precision20=\(format(metrics.precisionAt20)) "
                    + "thresholdRecall=\(format(thresholdRecall)) "
                    + "thresholdRetention=\(format(thresholdRetention)) "
                    + "below5=[\(belowThreshold)]"
            )
            print("SRBENCH-PLACEMENTS review=\(manifest.id) \(placements)")
            #expect(thresholdRetention >= 0.95)
            #expect(
                metrics.criticalFamiliesBelowThreshold.isEmpty,
                "Critical study families scored below 5 for \(manifest.id): \(belowThreshold)"
            )
        }
        let thresholdRecall = totalThresholded / Double(totalGold)
        let thresholdRetention = Double(totalVisibleAvailable) / Double(totalAvailable)
        print(
            "SRBENCH-GLOBAL-TOTAL reviews=\(manifests.count) gold=\(totalGold) "
                + "thresholdRecall=\(format(thresholdRecall)) "
                + "thresholdRetention=\(format(thresholdRetention))"
        )
        #expect(thresholdRetention >= 0.95)
        if requestedReviewID == nil {
            #expect(thresholdRecall >= 0.95)
        }
    }

    private func evidenceCards(
        candidates: [Work],
        manifest: SRBenchmarkManifest,
        configuration: AIProviderConfiguration
    ) async -> ([StructuredEvidenceCard], Int) {
        let service = FullTextService()
        let defaults = UserDefaults(suiteName: "com.local.RagBio") ?? .standard
        let openAlexKey = CredentialStore.string(for: .openAlexAPIKey)
        let semanticScholarKey = CredentialStore.string(for: .semanticScholarAPIKey)
        let contactEmail = defaults.string(forKey: SettingsKeys.contactEmail)
        let fullTextCandidates = Array(candidates.prefix(120))
        var documents: [String: FullTextDocument] = [:]

        await withTaskGroup(of: (String, FullTextDocument?).self) { group in
            var next = 0
            func enqueue(_ work: Work) {
                group.addTask {
                    let document = await SearchStore.loadFullTextWithSoftTimeout(
                        service: service,
                        work: work,
                        apiKey: openAlexKey.isEmpty ? nil : openAlexKey,
                        contactEmail: contactEmail,
                        semanticScholarAPIKey: semanticScholarKey.isEmpty
                            ? nil
                            : semanticScholarKey,
                        seconds: 6
                    )
                    return (work.id, document)
                }
            }
            while next < min(12, fullTextCandidates.count) {
                enqueue(fullTextCandidates[next])
                next += 1
            }
            for await (workID, document) in group {
                if let document, document.source.isFullText {
                    documents[workID] = document
                }
                if next < fullTextCandidates.count {
                    enqueue(fullTextCandidates[next])
                    next += 1
                }
            }
        }

        let query = evidenceQuery(
            originalRequest: manifest.question.naturalLanguageInput,
            retrievalQuery: manifest.question.structuredInput
        )
        let preparedQuery = HybridRetriever.prepare(query: query)
        let allowance = SearchStore.newEmbeddingAllowance(
            fullTextDocumentCount: documents.count
        )
        var inputs: [AIEvidenceRankingInput] = []
        for work in candidates {
            let document = documents[work.id]
            let passages: [PassageHit]
            if let document {
                passages = await HybridRetriever.searchCached(
                    preparedQuery: preparedQuery,
                    workID: work.id,
                    paragraphs: document.paragraphs,
                    limit: HybridRetriever.evidencePassageLimit,
                    maximumNewEmbeddings: allowance
                ).hits
            } else {
                passages = []
            }
            inputs.append(
                AIEvidenceRankingInput(
                    work: work,
                    abstract: work.abstractText,
                    passages: passages,
                    source: document?.source
                )
            )
        }

        let planner = AIQueryPlanner()
        let ranges = stride(from: 0, to: inputs.count, by: 12).map {
            $0..<min($0 + 12, inputs.count)
        }
        var cardsByIndex: [Int: StructuredEvidenceCard] = [:]
        await withTaskGroup(of: (Range<Int>, [AIEvidenceCardOutput]?).self) { group in
            var next = 0
            func enqueue(_ range: Range<Int>) {
                let batch = Array(inputs[range])
                group.addTask {
                    let outputs = try? await planner.analyzeEvidenceBatch(
                        description: manifest.question.naturalLanguageInput,
                        profile: manifest.question.profile,
                        inputs: batch,
                        configuration: configuration
                    )
                    return (range, outputs)
                }
            }
            while next < min(6, ranges.count) {
                enqueue(ranges[next])
                next += 1
            }
            for await (range, outputs) in group {
                let outputByIndex = outputs.map {
                    Dictionary(uniqueKeysWithValues: $0.map { ($0.index, $0) })
                } ?? [:]
                for absoluteIndex in range {
                    let input = inputs[absoluteIndex]
                    let local = LocalEvidenceCardBuilder.make(
                        work: input.work,
                        profile: manifest.question.profile,
                        abstract: input.abstract,
                        passages: input.passages,
                        hasFullText: input.hasFullTextEvidence
                    )
                    let relativeIndex = absoluteIndex - range.lowerBound
                    cardsByIndex[absoluteIndex] = outputByIndex[relativeIndex].map {
                        SearchStore.evidenceCard(
                            output: $0,
                            work: input.work,
                            local: local
                        )
                    } ?? local
                }
                if next < ranges.count {
                    enqueue(ranges[next])
                    next += 1
                }
            }
        }

        var cards = inputs.indices.map { index in
            cardsByIndex[index] ?? LocalEvidenceCardBuilder.make(
                work: inputs[index].work,
                profile: manifest.question.profile,
                abstract: inputs[index].abstract,
                passages: inputs[index].passages,
                hasFullText: inputs[index].hasFullTextEvidence
            )
        }
        let verificationIndices = inputs.indices.filter { index in
            let local = LocalEvidenceCardBuilder.make(
                work: inputs[index].work,
                profile: manifest.question.profile,
                abstract: inputs[index].abstract,
                passages: inputs[index].passages,
                hasFullText: inputs[index].hasFullTextEvidence
            )
            return SearchStore.needsCoreMismatchVerification(
                model: cards[index],
                local: local
            )
        }
        await withTaskGroup(of: (Int, AIEvidenceCardOutput?).self) { group in
            var next = 0
            func enqueue(_ index: Int) {
                group.addTask {
                    let output = try? await planner.analyzeEvidenceBatch(
                        description: manifest.question.naturalLanguageInput,
                        profile: manifest.question.profile,
                        inputs: [inputs[index]],
                        configuration: configuration
                    ).first
                    return (index, output)
                }
            }
            while next < min(6, verificationIndices.count) {
                enqueue(verificationIndices[next])
                next += 1
            }
            for await (index, output) in group {
                let local = LocalEvidenceCardBuilder.make(
                    work: inputs[index].work,
                    profile: manifest.question.profile,
                    abstract: inputs[index].abstract,
                    passages: inputs[index].passages,
                    hasFullText: inputs[index].hasFullTextEvidence
                )
                if let output {
                    let verified = SearchStore.evidenceCard(
                        output: output,
                        work: inputs[index].work,
                        local: local
                    )
                    cards[index] = SearchStore.protectingStrongLocalCoreMatches(
                        in: verified,
                        supportedBy: local
                    )
                } else {
                    cards[index] = SearchStore.softeningUnverifiedCoreMismatches(
                        in: cards[index],
                        supportedBy: local
                    )
                }
                if next < verificationIndices.count {
                    enqueue(verificationIndices[next])
                    next += 1
                }
            }
        }
        return (cards, documents.count)
    }

    private func evidenceQuery(
        originalRequest: String,
        retrievalQuery: String
    ) -> String {
        let stopwords: Set<String> = [
            "the", "and", "or", "not", "for", "with", "from", "into", "onto", "about",
            "between", "among", "using", "based", "study", "studies", "review",
            "analysis", "association", "relationship", "effect", "effects", "impact",
            "in", "on", "of", "to", "a", "an", "is", "are"
        ]
        return "\(originalRequest) \(retrievalQuery)"
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 && !stopwords.contains($0) }
            .uniqued()
            .joined(separator: " ")
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

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
