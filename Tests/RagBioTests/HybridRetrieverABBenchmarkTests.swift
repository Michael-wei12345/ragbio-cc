import Foundation
import Testing
@testable import RagBio

@Suite(.serialized)
struct HybridRetrieverABBenchmarkTests {
    @Test func diagnoseBudgetedEvidenceForSingleTarget() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RAGBIO_RUN_AB_TARGET"] == "1" else { return }
        let recordPath = try #require(environment["RAGBIO_AB_RECORD_PATH"])
        let cachePath = try #require(environment["RAGBIO_AB_CACHE_PATH"])
        let targetID = environment["RAGBIO_AB_TARGET_ID"]
            ?? "https://openalex.org/W2146384083"
        let record = try JSONDecoder().decode(
            SearchHistoryRecord.self,
            from: Data(contentsOf: URL(fileURLWithPath: recordPath))
        )
        let work = try #require(
            record.snapshot.candidateWorks.first(where: { $0.id == targetID })
        )
        let fullTextCache = FullTextCache(
            directory: URL(fileURLWithPath: cachePath, isDirectory: true)
        )
        let document = try #require(await fullTextCache.load(workID: work.id))
        let preparedQuery = HybridRetriever.prepare(query: record.snapshot.retrievalQuery)
        let temporaryRoot = try makeTemporaryDirectory()
            .appendingPathComponent("TargetEmbeddings", isDirectory: true)
        let result = await HybridRetriever.searchCached(
            preparedQuery: preparedQuery,
            workID: work.id,
            paragraphs: document.paragraphs,
            limit: HybridRetriever.evidencePassageLimit,
            maximumNewEmbeddings: 8,
            cache: ParagraphEmbeddingCache(directory: temporaryRoot)
        )
        let input = AIEvidenceRankingInput(
            work: work,
            abstract: work.abstractText,
            passages: result.hits,
            source: document.source
        )
        let planner = AIQueryPlanner()
        let output = try #require(
            try await planner.analyzeEvidenceBatch(
                description: record.displayQuery,
                profile: record.snapshot.lastAIPlan?.questionProfile,
                inputs: [input],
                configuration: configuredProvider()
            ).first
        )
        let local = LocalEvidenceCardBuilder.make(
            work: work,
            profile: record.snapshot.lastAIPlan?.questionProfile,
            abstract: input.abstract,
            passages: input.passages,
            hasFullText: true
        )
        let modelCard = StructuredEvidenceCard(
            workID: work.id,
            population: output.population,
            interventionOrExposure: output.interventionOrExposure,
            comparator: output.comparator,
            outcome: output.outcome,
            context: output.context,
            role: SearchStore.resolvedEvidenceRole(output.role, for: work),
            reportsEffectEstimate: output.reportsEffectEstimate,
            reportsSampleSize: output.reportsSampleSize,
            hasComparatorGroup: output.hasComparatorGroup,
            reportsFollowUp: output.reportsFollowUp,
            uniqueContribution: output.uniqueContribution,
            confidence: local.confidence,
            studyFamilyID: local.studyFamilyID,
            evidenceBasis: local.evidenceBasis
        )
        let report = TargetDiagnosticReport(
            title: work.title,
            generatedEmbeddingCount: result.generatedEmbeddingCount,
            passages: result.hits.map {
                TargetPassageDiagnostic(
                    id: $0.paragraph.id,
                    section: $0.paragraph.section,
                    score: $0.score,
                    matchedTerms: $0.matchedTerms,
                    preview: String($0.paragraph.text.prefix(600))
                )
            },
            localCard: local,
            localScore: EvidenceUsefulnessScorer.score(local),
            modelCard: modelCard,
            modelCardLocalScore: EvidenceUsefulnessScorer.score(modelCard),
            oldCard: record.snapshot.evidenceCards[work.id],
            oldScore: record.snapshot.aiScores[work.id]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print("RAGBIO_AB_TARGET_REPORT_BEGIN")
        print(String(data: try encoder.encode(report), encoding: .utf8) ?? "{}")
        print("RAGBIO_AB_TARGET_REPORT_END")
    }

    @Test func compareLegacyFullSemanticEvidenceWithBudgetedEvidence() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RAGBIO_RUN_AB"] == "1" else { return }
        let recordPath = try #require(environment["RAGBIO_AB_RECORD_PATH"])
        let cachePath = try #require(environment["RAGBIO_AB_CACHE_PATH"])
        let record = try JSONDecoder().decode(
            SearchHistoryRecord.self,
            from: Data(contentsOf: URL(fileURLWithPath: recordPath))
        )
        let candidates = record.snapshot.candidateWorks
        #expect(!candidates.isEmpty)
        let targetIDs = [
            "https://openalex.org/W2149908785",
            "https://pubmed.ncbi.nlm.nih.gov/28215665",
            "https://openalex.org/W2146384083",
            "https://openalex.org/W3126817559",
            "https://openalex.org/W2095633632",
            "https://openalex.org/W3165177412",
            "https://pubmed.ncbi.nlm.nih.gov/26874901",
            "https://pubmed.ncbi.nlm.nih.gov/33932503"
        ]

        let sourceDirectory = URL(fileURLWithPath: cachePath, isDirectory: true)
        let fullTextCache = FullTextCache(directory: sourceDirectory)
        var documents: [String: FullTextDocument] = [:]
        for work in candidates {
            if let document = await fullTextCache.load(workID: work.id),
               document.source.isFullText {
                documents[work.id] = document
            }
        }
        #expect(!documents.isEmpty)

        let preparedQuery = HybridRetriever.prepare(query: record.snapshot.retrievalQuery)
        var legacyResults: [String: HybridPassageSearchResult] = [:]
        let legacyRetrievalStartedAt = Date()
        for id in targetIDs {
            guard let document = documents[id] else { continue }
            legacyResults[id] = HybridPassageSearchResult(
                hits: HybridRetriever.search(
                    preparedQuery: preparedQuery,
                    paragraphs: document.paragraphs,
                    limit: 4
                ),
                cachedEmbeddingCount: 0,
                generatedEmbeddingCount: min(
                    HybridRetriever.maximumSemanticCandidates,
                    document.paragraphs.count
                )
            )
        }
        let legacyRetrievalSeconds = Date().timeIntervalSince(legacyRetrievalStartedAt)

        let temporaryRoot = try makeTemporaryDirectory()
            .appendingPathComponent("BudgetedEmbeddings", isDirectory: true)
        let budgetedCache = ParagraphEmbeddingCache(directory: temporaryRoot)
        let perDocumentAllowance = SearchStore.newEmbeddingAllowance(
            fullTextDocumentCount: documents.count
        )
        var budgetedResults: [String: HybridPassageSearchResult] = [:]
        var generatedEmbeddings = 0
        var maximumThermalState = ProcessInfo.processInfo.thermalState.rawValue
        let budgetedRetrievalStartedAt = Date()
        for work in candidates {
            guard let document = documents[work.id] else { continue }
            let result = await HybridRetriever.searchCached(
                preparedQuery: preparedQuery,
                workID: work.id,
                paragraphs: document.paragraphs,
                limit: HybridRetriever.evidencePassageLimit,
                maximumNewEmbeddings: perDocumentAllowance,
                cache: budgetedCache
            )
            budgetedResults[work.id] = result
            generatedEmbeddings += result.generatedEmbeddingCount
            maximumThermalState = max(
                maximumThermalState,
                ProcessInfo.processInfo.thermalState.rawValue
            )
        }
        let budgetedRetrievalSeconds = Date().timeIntervalSince(budgetedRetrievalStartedAt)
        #expect(generatedEmbeddings <= SearchStore.maximumNewEmbeddingsPerSearch)

        let legacyComparableIDs = targetIDs.filter { legacyResults[$0] != nil }
        let passageRecallValues = legacyComparableIDs.compactMap { id -> Double? in
            guard let legacy = legacyResults[id], let budgeted = budgetedResults[id] else {
                return nil
            }
            let expected = Set(legacy.hits.prefix(4).map(\.paragraph.id))
            guard !expected.isEmpty else { return nil }
            let actual = Set(budgeted.hits.map(\.paragraph.id))
            return Double(expected.intersection(actual).count) / Double(expected.count)
        }
        let meanLegacyPassageRecall = passageRecallValues.isEmpty
            ? 0
            : passageRecallValues.reduce(0, +) / Double(passageRecallValues.count)

        let configuration = try configuredProvider()
        let planner = AIQueryPlanner()
        let newInputs = candidates.map { work in
            AIEvidenceRankingInput(
                work: work,
                abstract: work.abstractText,
                passages: budgetedResults[work.id]?.hits ?? [],
                source: documents[work.id]?.source
            )
        }
        var newCardsByID = record.snapshot.evidenceCards
        let fullTextIndices = candidates.indices.filter { documents[candidates[$0].id] != nil }
        let aiStartedAt = Date()
        for start in stride(from: 0, to: fullTextIndices.count, by: 12) {
            let indexSlice = Array(
                fullTextIndices[start..<min(start + 12, fullTextIndices.count)]
            )
            let batch = indexSlice.map { newInputs[$0] }
            let outputs = try await planner.analyzeEvidenceBatch(
                description: record.displayQuery,
                profile: record.snapshot.lastAIPlan?.questionProfile,
                inputs: batch,
                configuration: configuration
            )
            let outputsByIndex = Dictionary(uniqueKeysWithValues: outputs.map {
                ($0.index, $0)
            })
            for relativeIndex in batch.indices {
                let input = batch[relativeIndex]
                let local = LocalEvidenceCardBuilder.make(
                    work: input.work,
                    profile: record.snapshot.lastAIPlan?.questionProfile,
                    abstract: input.abstract,
                    passages: input.passages,
                    hasFullText: input.hasFullTextEvidence
                )
                if let output = outputsByIndex[relativeIndex] {
                    newCardsByID[input.work.id] = SearchStore.evidenceCard(
                        output: output,
                        work: input.work,
                        local: local
                    )
                } else {
                    newCardsByID[input.work.id] = local
                }
            }
        }
        var mismatchVerificationCount = 0
        for index in fullTextIndices {
            let input = newInputs[index]
            guard let initial = newCardsByID[input.work.id] else { continue }
            let local = LocalEvidenceCardBuilder.make(
                work: input.work,
                profile: record.snapshot.lastAIPlan?.questionProfile,
                abstract: input.abstract,
                passages: input.passages,
                hasFullText: input.hasFullTextEvidence
            )
            guard SearchStore.needsCoreMismatchVerification(
                model: initial,
                local: local
            ) else { continue }
            mismatchVerificationCount += 1
            let verified = try? await planner.analyzeEvidenceBatch(
                description: record.displayQuery,
                profile: record.snapshot.lastAIPlan?.questionProfile,
                inputs: [input],
                configuration: configuration
            ).first
            if let verified {
                let verifiedCard = SearchStore.evidenceCard(
                    output: verified,
                    work: input.work,
                    local: local
                )
                newCardsByID[input.work.id] = SearchStore.protectingStrongLocalCoreMatches(
                    in: verifiedCard,
                    supportedBy: local
                )
            } else {
                newCardsByID[input.work.id] = SearchStore.softeningUnverifiedCoreMismatches(
                    in: initial,
                    supportedBy: local
                )
            }
        }

        let newCards = candidates.map { work in
            newCardsByID[work.id] ?? LocalEvidenceCardBuilder.make(
                work: work,
                profile: record.snapshot.lastAIPlan?.questionProfile,
                abstract: work.abstractText,
                passages: budgetedResults[work.id]?.hits ?? [],
                hasFullText: documents[work.id] != nil
            )
        }
        let localScores = newCards.map(EvidenceUsefulnessScorer.score)
        var globalOutputs = try await planner.calibrateGlobalScores(
            description: record.displayQuery,
            profile: record.snapshot.lastAIPlan?.questionProfile,
            cards: newCards,
            works: candidates,
            localScores: localScores,
            configuration: configuration
        )
        let returned = Set(globalOutputs.map(\.index))
        let missing = candidates.indices.filter { !returned.contains($0) }
        if !missing.isEmpty {
            let retry = try await planner.calibrateGlobalScores(
                description: record.displayQuery,
                profile: record.snapshot.lastAIPlan?.questionProfile,
                cards: missing.map { newCards[$0] },
                works: missing.map { candidates[$0] },
                localScores: missing.map { localScores[$0] },
                configuration: configuration
            )
            globalOutputs += retry.compactMap { output in
                guard missing.indices.contains(output.index) else { return nil }
                return output.withIndex(missing[output.index])
            }
        }
        let modelScores = try SearchStore.validatedGlobalScores(
            globalOutputs,
            candidateCount: candidates.count
        )
        let newScoresByIndex = SearchStore.anchoredGlobalScores(
            modelScores: modelScores,
            localScores: localScores,
            cards: newCards
        )
        let newRankedIndices = SearchStore.globallyRankedIndices(
            scores: newScoresByIndex,
            candidateCount: candidates.count,
            minimumScore: 5
        )
        let aiSeconds = Date().timeIntervalSince(aiStartedAt)

        let legacyRankedIDs = record.snapshot.rankedWorks.map(\.id)
        let newRankedIDs = newRankedIndices.map { candidates[$0].id }
        let oldRetained = Set(legacyRankedIDs)
        let newRetained = Set(newRankedIDs)
        let targetRows = targetIDs.compactMap { id -> TargetComparison? in
            guard let work = candidates.first(where: { $0.id == id }) else { return nil }
            let candidateIndex = candidates.firstIndex(where: { $0.id == id })
            return TargetComparison(
                title: work.title,
                oldRank: legacyRankedIDs.firstIndex(of: id).map { $0 + 1 },
                newRank: newRankedIDs.firstIndex(of: id).map { $0 + 1 },
                oldScore: record.snapshot.aiScores[id],
                newScore: candidateIndex.flatMap { newScoresByIndex[$0] },
                newCard: candidateIndex.map { newCards[$0] },
                newLocalScore: candidateIndex.map { localScores[$0] },
                legacyPassageRecall: passageRecall(id: id, legacy: legacyResults, new: budgetedResults)
            )
        }
        let scoreDeltas = candidates.indices.compactMap { index -> Int? in
            guard let old = record.snapshot.aiScores[candidates[index].id],
                  let new = newScoresByIndex[index] else { return nil }
            return abs(old - new)
        }
        let lostRows = oldRetained.subtracting(newRetained).compactMap { id -> ThresholdComparison? in
            guard let work = candidates.first(where: { $0.id == id }),
                  let index = candidates.firstIndex(where: { $0.id == id }) else { return nil }
            return ThresholdComparison(
                title: work.title,
                oldScore: record.snapshot.aiScores[id],
                newScore: newScoresByIndex[index]
            )
        }
        .sorted { ($0.oldScore ?? 0) > ($1.oldScore ?? 0) }
        let report = BenchmarkReport(
            query: record.snapshot.retrievalQuery,
            provider: configuration.provider.rawValue,
            model: configuration.model,
            candidateCount: candidates.count,
            fullTextDocumentCount: documents.count,
            legacyComparableDocumentCount: legacyComparableIDs.count,
            perDocumentEmbeddingAllowance: perDocumentAllowance,
            generatedEmbeddingCount: generatedEmbeddings,
            mismatchVerificationCount: mismatchVerificationCount,
            legacyRetrievalSecondsFromCache: legacyRetrievalSeconds,
            budgetedColdRetrievalSeconds: budgetedRetrievalSeconds,
            aiSeconds: aiSeconds,
            maximumThermalState: thermalStateName(maximumThermalState),
            meanLegacyTop4PassageRecallInNewTop6: meanLegacyPassageRecall,
            top20Overlap: overlap(legacyRankedIDs, newRankedIDs, limit: 20),
            top50Overlap: overlap(legacyRankedIDs, newRankedIDs, limit: 50),
            meanAbsoluteScoreDelta: scoreDeltas.isEmpty
                ? 0
                : Double(scoreDeltas.reduce(0, +)) / Double(scoreDeltas.count),
            oldRetainedCount: oldRetained.count,
            newRetainedCount: newRetained.count,
            lostAtThresholdCount: oldRetained.subtracting(newRetained).count,
            gainedAtThresholdCount: newRetained.subtracting(oldRetained).count,
            lostAtThreshold: lostRows,
            targets: targetRows
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportText = String(
            data: try encoder.encode(report),
            encoding: .utf8
        ) ?? "{}"
        print("RAGBIO_AB_REPORT_BEGIN")
        print(reportText)
        print("RAGBIO_AB_REPORT_END")
    }

    private func configuredProvider() throws -> AIProviderConfiguration {
        let defaults = try #require(UserDefaults(suiteName: "com.local.RagBio"))
        let provider = defaults.string(forKey: SettingsKeys.activeAIProvider)
            .flatMap(AIProvider.init(rawValue:)) ?? .openAI
        let model = defaults.string(forKey: SettingsKeys.aiModel(provider))
            ?? provider.defaultModel
        let baseURL = defaults.string(forKey: SettingsKeys.aiBaseURL(provider))
            ?? provider.defaultBaseURL
        let configuration = AIProviderConfiguration(
            provider: provider,
            apiKey: CredentialStore.string(for: provider.credentialKey),
            model: model,
            baseURL: baseURL
        )
        #expect(configuration.isConfigured)
        return configuration
    }

    private func overlap(_ old: [String], _ new: [String], limit: Int) -> Double {
        let oldSet = Set(old.prefix(limit))
        guard !oldSet.isEmpty else { return 0 }
        return Double(oldSet.intersection(Set(new.prefix(limit))).count) / Double(oldSet.count)
    }

    private func passageRecall(
        id: String,
        legacy: [String: HybridPassageSearchResult],
        new: [String: HybridPassageSearchResult]
    ) -> Double? {
        guard let oldResult = legacy[id], let newResult = new[id] else { return nil }
        let oldIDs = Set(oldResult.hits.prefix(4).map(\.paragraph.id))
        guard !oldIDs.isEmpty else { return nil }
        let newIDs = Set(newResult.hits.map(\.paragraph.id))
        return Double(oldIDs.intersection(newIDs).count) / Double(oldIDs.count)
    }

    private func thermalStateName(_ value: Int) -> String {
        switch value {
        case ProcessInfo.ThermalState.nominal.rawValue: return "nominal"
        case ProcessInfo.ThermalState.fair.rawValue: return "fair"
        case ProcessInfo.ThermalState.serious.rawValue: return "serious"
        case ProcessInfo.ThermalState.critical.rawValue: return "critical"
        default: return "unknown"
        }
    }
}

private struct TargetDiagnosticReport: Codable {
    let title: String
    let generatedEmbeddingCount: Int
    let passages: [TargetPassageDiagnostic]
    let localCard: StructuredEvidenceCard
    let localScore: Int
    let modelCard: StructuredEvidenceCard
    let modelCardLocalScore: Int
    let oldCard: StructuredEvidenceCard?
    let oldScore: Int?
}

private struct TargetPassageDiagnostic: Codable {
    let id: String
    let section: String
    let score: Double
    let matchedTerms: [String]
    let preview: String
}

private struct BenchmarkReport: Codable {
    let query: String
    let provider: String
    let model: String
    let candidateCount: Int
    let fullTextDocumentCount: Int
    let legacyComparableDocumentCount: Int
    let perDocumentEmbeddingAllowance: Int
    let generatedEmbeddingCount: Int
    let mismatchVerificationCount: Int
    let legacyRetrievalSecondsFromCache: Double
    let budgetedColdRetrievalSeconds: Double
    let aiSeconds: Double
    let maximumThermalState: String
    let meanLegacyTop4PassageRecallInNewTop6: Double
    let top20Overlap: Double
    let top50Overlap: Double
    let meanAbsoluteScoreDelta: Double
    let oldRetainedCount: Int
    let newRetainedCount: Int
    let lostAtThresholdCount: Int
    let gainedAtThresholdCount: Int
    let lostAtThreshold: [ThresholdComparison]
    let targets: [TargetComparison]
}

private struct ThresholdComparison: Codable {
    let title: String
    let oldScore: Int?
    let newScore: Int?
}

private struct TargetComparison: Codable {
    let title: String
    let oldRank: Int?
    let newRank: Int?
    let oldScore: Int?
    let newScore: Int?
    let newCard: StructuredEvidenceCard?
    let newLocalScore: Int?
    let legacyPassageRecall: Double?
}
