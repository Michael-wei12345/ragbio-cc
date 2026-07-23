import Foundation
import Testing
@testable import RagBio

@Suite(.serialized) struct AIEvidenceRankingTests {
    @Test func sourceLocatorsStayEnglishForNewAndCachedSummaries() {
        let paragraph = FullTextParagraph(
            id: "p1",
            section: "PDF 正文",
            text: "Full text evidence",
            ordinal: 3,
            page: 8
        )

        #expect(paragraph.locator == "PDF full text · Paragraph 3 · Page 8")
        #expect(
            SourceLocatorFormatter.english("[PDF 正文 · 第 1 段; 第 2 段]")
                == "[PDF full text · Paragraph 1; Paragraph 2]"
        )
    }

    @Test func evidenceCardAnalysisSendsRetrievedPassagesToTheModel() async throws {
        EvidenceRankingURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [EvidenceRankingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let work = makeWork(title: "Poliovirus paper")
        let paragraph = FullTextParagraph(
            id: "p1",
            section: "Results",
            text: "POLIO_ETIOLOGY_MARKER identifies the causal viral mechanism.",
            ordinal: 1,
            page: 3
        )
        let input = AIEvidenceRankingInput(
            work: work,
            abstract: "Abstract evidence",
            passages: [
                PassageHit(id: "hit-1", paragraph: paragraph, score: 1, matchedTerms: ["polio"])
            ],
            source: .europePMC
        )
        let configuration = AIProviderConfiguration(
            provider: .openAI,
            apiKey: "test-key",
            model: "test-model",
            baseURL: "https://example.test"
        )

        let cards = try await AIQueryPlanner(session: session).analyzeEvidenceBatch(
            description: "Etiology of poliomyelitis",
            profile: ResearchQuestionProfile(
                questionType: .etiology,
                population: ["poliomyelitis"],
                interventionOrExposure: ["poliovirus"],
                comparator: [],
                outcomes: [],
                context: [],
                preferredStudyDesigns: []
            ),
            inputs: [input],
            configuration: configuration
        )

        #expect(cards.map(\.index) == [0])
        #expect(cards.map(\.population) == [.match])
        #expect(cards.map(\.role) == [.primary])
        #expect(
            EvidenceRankingURLProtocol.prompts.contains {
                $0.contains("POLIO_ETIOLOGY_MARKER")
                    && $0.contains("depression measured only in parents or caregivers")
            }
        )
    }

    @Test func abstractFallbackParticipatesInEvidenceCardAnalysis() async throws {
        EvidenceRankingURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [EvidenceRankingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let work = makeWork(title: "Abstract only paper")
        let configuration = AIProviderConfiguration(
            provider: .openAI,
            apiKey: "test-key",
            model: "test-model",
            baseURL: "https://example.test"
        )

        let cards = try await AIQueryPlanner(session: session).analyzeEvidenceBatch(
            description: "Etiology of poliomyelitis",
            profile: nil,
            inputs: [
                AIEvidenceRankingInput(
                    work: work,
                    abstract: "ABSTRACT_ONLY_MARKER describes the viral cause.",
                    passages: [],
                    source: nil
                )
            ],
            configuration: configuration
        )

        #expect(cards.map(\.index) == [0])
        #expect(
            EvidenceRankingURLProtocol.prompts.contains {
                $0.contains("ABSTRACT_ONLY_MARKER") && $0.contains("Evidence excerpts: Not available")
            }
        )
    }

    @Test func evidenceCardAnalysisUsesSixPassagesWithoutGrowingItsOutputSchema() async throws {
        EvidenceRankingURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [EvidenceRankingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let work = makeWork(title: "Six passage paper")
        let passages = (0..<7).map { index in
            PassageHit(
                id: "hit-\(index)",
                paragraph: FullTextParagraph(
                    id: "p-\(index)",
                    section: ["Abstract", "Methods", "Methods", "Results", "Results", "Discussion", "Other"][index],
                    text: "SIX_PASSAGE_MARKER_\(index)",
                    ordinal: index,
                    page: nil
                ),
                score: Double(10 - index),
                matchedTerms: []
            )
        }
        let configuration = AIProviderConfiguration(
            provider: .openAI,
            apiKey: "test-key",
            model: "test-model",
            baseURL: "https://example.test"
        )

        _ = try await AIQueryPlanner(session: session).analyzeEvidenceBatch(
            description: "Child gastrointestinal disease and depression",
            profile: nil,
            inputs: [
                AIEvidenceRankingInput(
                    work: work,
                    abstract: "Abstract evidence",
                    passages: passages,
                    source: .europePMC
                )
            ],
            configuration: configuration
        )

        let prompt = try #require(EvidenceRankingURLProtocol.prompts.last)
        for index in 0..<6 {
            #expect(prompt.contains("SIX_PASSAGE_MARKER_\(index)"))
        }
        #expect(!prompt.contains("SIX_PASSAGE_MARKER_6"))
        #expect(prompt.contains(#""reports_effect_estimate":false"#))
    }

    @Test func evidenceAnalysisUsesSmallIndependentBatches() {
        #expect(
            SearchStore.evidenceBatchRanges(totalCount: 30, batchSize: 12)
                == [0..<12, 12..<24, 24..<30]
        )
    }

    @Test func expandedEvidencePoolDoesNotExpandAutomaticFullTextWork() {
        let works = (0..<180).map {
            makeWork(id: "W\($0)", doi: "10.1000/\($0)")
        }

        let fullText = SearchStore.fullTextPreparationCandidates(works, limit: 120)

        #expect(fullText.count == 120)
        #expect(fullText.first?.id == "W0")
        #expect(fullText.last?.id == "W119")
    }

    @Test func candidateTriageIsConservativeAndDoesNotRequestFinalScoresOrReasons() async throws {
        EvidenceRankingURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [EvidenceRankingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let configuration = AIProviderConfiguration(
            provider: .openAI,
            apiKey: "test-key",
            model: "test-model",
            baseURL: "https://example.test"
        )

        let output = try await AIQueryPlanner(session: session).triageCandidateBatch(
            description: "Shorter versus one-year adjuvant trastuzumab",
            profile: nil,
            works: [
                makeWork(
                    title: "TRIAGE_MARKER randomized trastuzumab duration trial",
                    abstract: "Direct comparison in early HER2-positive breast cancer."
                )
            ],
            configuration: configuration
        )

        #expect(output.first?.disposition == .likely)
        #expect(output.first?.directness == 3)
        let prompt = try #require(
            EvidenceRankingURLProtocol.prompts.first { $0.contains("TRIAGE_MARKER") }
        )
        #expect(prompt.contains("Unknown is never mismatch"))
        #expect(prompt.contains("NOT final inclusion"))
        #expect(!prompt.contains(#""score""#))
        #expect(!prompt.contains(#""reason""#))
    }

    @Test func globalCalibrationUsesCompactCardsAndDoesNotRequestReasons() async throws {
        EvidenceRankingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EvidenceRankingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let work = makeWork(title: "APT trial")
        let card = StructuredEvidenceCard(
            workID: work.id,
            population: .match,
            interventionOrExposure: .match,
            comparator: .partial,
            outcome: .match,
            context: .match,
            role: .primary,
            reportsEffectEstimate: true,
            reportsSampleSize: true,
            hasComparatorGroup: false,
            reportsFollowUp: true,
            uniqueContribution: true,
            confidence: .high,
            studyFamilyID: "acronym:APT",
            evidenceBasis: "full_text"
        )
        let provider = AIProviderConfiguration(
            provider: .openAI,
            apiKey: "test-key",
            model: "test-model",
            baseURL: "https://example.test"
        )

        let output = try await AIQueryPlanner(session: session).calibrateGlobalScores(
            description: "HER2 adjuvant therapy",
            profile: nil,
            cards: [card],
            works: [work],
            localScores: [88],
            configuration: provider
        )

        #expect(output == [AIGlobalScoreOutput(index: 0, score: 91)])
        let calibrationPrompts = EvidenceRankingURLProtocol.prompts.filter {
            $0.contains("Evidence cards:")
        }
        #expect(!calibrationPrompts.isEmpty)
        #expect(calibrationPrompts.allSatisfy { !$0.contains(#""reason""#) })
        #expect(calibrationPrompts.allSatisfy { $0.contains("90-100: direct evidence") })
    }

    @Test func globalScoresFilterFourKeepFiveAndKeepStableTies() {
        let ranked = SearchStore.globallyRankedIndices(
            scores: [0: 5, 1: 4, 2: 80, 3: 80, 4: 12],
            candidateCount: 5,
            minimumScore: 5
        )

        #expect(ranked == [2, 3, 4, 0])
    }

    @Test func deterministicRubricAnchorsGlobalModelScores() {
        func card(
            _ population: EvidenceMatch,
            outcome: EvidenceMatch = .match
        ) -> StructuredEvidenceCard {
            StructuredEvidenceCard(
                workID: UUID().uuidString,
                population: population,
                interventionOrExposure: .match,
                comparator: .unclear,
                outcome: outcome,
                context: .match,
                role: .primary,
                reportsEffectEstimate: true,
                reportsSampleSize: true,
                hasComparatorGroup: true,
                reportsFollowUp: true,
                uniqueContribution: false,
                confidence: .medium,
                studyFamilyID: nil,
                evidenceBasis: "abstract"
            )
        }
        let scores = SearchStore.anchoredGlobalScores(
            modelScores: [0: 99, 1: 80, 2: 90],
            localScores: [4, 80, 70],
            cards: [
                card(.mismatch),
                card(.match),
                card(.match, outcome: .mismatch)
            ]
        )

        #expect(scores[0] == 4)
        #expect(scores[1] == 80)
        #expect(scores[2] == 4)
    }

    @Test func conflictingCoreMismatchRequiresSinglePaperVerification() {
        func card(
            population: EvidenceMatch,
            intervention: EvidenceMatch,
            outcome: EvidenceMatch
        ) -> StructuredEvidenceCard {
            StructuredEvidenceCard(
                workID: "W1",
                population: population,
                interventionOrExposure: intervention,
                comparator: .match,
                outcome: outcome,
                context: .match,
                role: .primary,
                reportsEffectEstimate: true,
                reportsSampleSize: true,
                hasComparatorGroup: true,
                reportsFollowUp: true,
                uniqueContribution: true,
                confidence: .high,
                studyFamilyID: nil,
                evidenceBasis: "full_text"
            )
        }
        let batched = card(
            population: .mismatch,
            intervention: .partial,
            outcome: .mismatch
        )
        let local = card(
            population: .partial,
            intervention: .match,
            outcome: .match
        )

        #expect(SearchStore.needsCoreMismatchVerification(model: batched, local: local))
        let softened = SearchStore.softeningUnverifiedCoreMismatches(
            in: batched,
            supportedBy: local
        )
        #expect(softened.population == .unclear)
        #expect(softened.outcome == .unclear)
        #expect(softened.interventionOrExposure == .partial)

        let verifiedButConflicting = SearchStore.protectingStrongLocalCoreMatches(
            in: batched,
            supportedBy: local
        )
        #expect(verifiedButConflicting.population == .unclear)
        #expect(verifiedButConflicting.interventionOrExposure == .partial)
        #expect(verifiedButConflicting.outcome == .mismatch)
    }

    @Test func explicitPublicationTypeOverridesAnIncorrectAIPrimaryRole() {
        let review = makeWork(publicationTypes: ["Systematic Review", "Meta-Analysis"])
        let protocolWork = makeWork(publicationTypes: ["Clinical Trial Protocol"])
        let registry = makeWork(
            id: "https://clinicaltrials.gov/study/NCT12345678",
            publicationTypes: ["Clinical Trial Registry"]
        )

        #expect(SearchStore.resolvedEvidenceRole(.primary, for: review) == .background)
        #expect(SearchStore.resolvedEvidenceRole(.primary, for: protocolWork) == .protocolRecord)
        #expect(SearchStore.resolvedEvidenceRole(.primary, for: registry) == .registry)
    }

    @Test func semanticPassageWorkIsBoundedForLongDocuments() {
        #expect(HybridRetriever.maximumSemanticCandidates == 56)
        #expect(HybridRetriever.maximumNewEmbeddingsPerDocument == 12)
        #expect(HybridRetriever.evidencePassageLimit == 6)
        let paragraphs = (0..<200).map { index in
            FullTextParagraph(
                id: "p-\(index)",
                section: index % 2 == 0 ? "Methods" : "Results",
                text: "Pediatric gastrointestinal disease and depressive symptoms paragraph \(index).",
                ordinal: index,
                page: nil
            )
        }
        let hits = HybridRetriever.search(
            query: "child gastrointestinal disease depression",
            paragraphs: paragraphs,
            limit: HybridRetriever.evidencePassageLimit
        )
        #expect(hits.count <= HybridRetriever.evidencePassageLimit)
        #expect(!hits.isEmpty)
    }

    @Test func newEmbeddingBudgetIsSharedFairlyAcrossAllFullTextDocuments() {
        #expect(SearchStore.newEmbeddingAllowance(fullTextDocumentCount: 0) == 0)
        #expect(SearchStore.newEmbeddingAllowance(fullTextDocumentCount: 35) == 12)
        #expect(SearchStore.newEmbeddingAllowance(fullTextDocumentCount: 50) == 10)
        #expect(SearchStore.newEmbeddingAllowance(fullTextDocumentCount: 120) == 4)

        for count in 1...120 {
            let allowance = SearchStore.newEmbeddingAllowance(fullTextDocumentCount: count)
            #expect(
                allowance * count <= SearchStore.maximumNewEmbeddingsPerSearch
            )
        }
    }

    @Test func evidenceSelectionPreservesCoreSectionsAndTheStrongestExtraEvidence() {
        func hit(_ id: String, section: String, score: Double) -> PassageHit {
            PassageHit(
                id: id,
                paragraph: FullTextParagraph(
                    id: id,
                    section: section,
                    text: "\(section) evidence \(id)",
                    ordinal: Int(id.dropFirst()) ?? 0,
                    page: nil
                ),
                score: score,
                matchedTerms: []
            )
        }
        let ranked = [
            hit("p0", section: "Introduction", score: 1.0),
            hit("p1", section: "Results", score: 0.9),
            hit("p2", section: "Methods", score: 0.8),
            hit("p3", section: "Discussion", score: 0.7),
            hit("p4", section: "Abstract", score: 0.6),
            hit("p5", section: "Results", score: 0.5),
            hit("p6", section: "Methods", score: 0.4)
        ]

        let selected = HybridRetriever.selectEvidenceDiverse(ranked, limit: 6)
        let sections = Set(selected.map { HybridRetriever.sectionKind($0.paragraph.section) })

        #expect(selected.count == 6)
        #expect(sections.isSuperset(of: ["abstract", "methods", "results", "discussion"]))
        #expect(selected.contains { $0.id == "p0" })
    }

    @Test func embeddedPDFHeadingsCountAsCoreEvidenceSections() {
        let paragraphs = [
            FullTextParagraph(
                id: "a",
                section: "PDF 正文",
                text: "Original article abstract background and objectives.",
                ordinal: 0,
                page: 1
            ),
            FullTextParagraph(
                id: "m",
                section: "PDF 正文",
                text: ". methods Participants were randomized to treatment or control.",
                ordinal: 1,
                page: 2
            ),
            FullTextParagraph(
                id: "r",
                section: "PDF 正文",
                text: ". results Disease-free survival improved.",
                ordinal: 2,
                page: 3
            ),
            FullTextParagraph(
                id: "d",
                section: "PDF 正文",
                text: ". discussion These findings support adjuvant treatment.",
                ordinal: 3,
                page: 4
            )
        ]

        #expect(paragraphs.map(HybridRetriever.sectionKind) == [
            "abstract", "methods", "results", "discussion"
        ])
    }

    @Test func embeddingGenerationStartsWithCoreEvidenceSections() {
        let rows: [(FullTextParagraph, Double, [String])] = [
            ("p0", "Introduction", 10),
            ("p1", "Abstract", 1),
            ("p2", "Methods", 2),
            ("p3", "Methods", 1),
            ("p4", "Results", 3),
            ("p5", "Results", 2),
            ("p6", "Discussion", 1),
            ("p7", "Other", 9)
        ].map { id, section, score in
            (
                FullTextParagraph(
                    id: id,
                    section: section,
                    text: "\(section) evidence",
                    ordinal: Int(id.dropFirst()) ?? 0,
                    page: nil
                ),
                Double(score),
                []
            )
        }

        let ordered = HybridRetriever.embeddingGenerationCandidateIndices(
            rows,
            candidateIndices: Array(rows.indices)
        )
        let firstSixKinds = ordered.prefix(6).map {
            HybridRetriever.sectionKind(rows[$0].0.section)
        }

        #expect(firstSixKinds.filter { $0 == "abstract" }.count == 1)
        #expect(firstSixKinds.filter { $0 == "methods" }.count == 2)
        #expect(firstSixKinds.filter { $0 == "results" }.count == 2)
        #expect(firstSixKinds.filter { $0 == "discussion" }.count == 1)
    }

    @Test func exhaustedEmbeddingBudgetStillReturnsSectionBalancedFullTextEvidence() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("FullText")
        let cache = ParagraphEmbeddingCache(directory: root)
        let paragraphs = [
            FullTextParagraph(id: "i", section: "Introduction", text: "Target disease context.", ordinal: 0, page: nil),
            FullTextParagraph(id: "a", section: "Abstract", text: "Study overview.", ordinal: 1, page: nil),
            FullTextParagraph(id: "m1", section: "Methods", text: "Participants and eligibility.", ordinal: 2, page: nil),
            FullTextParagraph(id: "m2", section: "Methods", text: "Statistical analysis.", ordinal: 3, page: nil),
            FullTextParagraph(id: "r1", section: "Results", text: "Primary outcome result.", ordinal: 4, page: nil),
            FullTextParagraph(id: "r2", section: "Results", text: "Secondary outcome result.", ordinal: 5, page: nil),
            FullTextParagraph(id: "d", section: "Discussion", text: "Interpretation and limitations.", ordinal: 6, page: nil)
        ]

        let result = await HybridRetriever.searchCached(
            preparedQuery: HybridRetrievalQuery(
                text: "target disease",
                terms: ["target", "disease"],
                vector: nil
            ),
            workID: "W-no-embedding-budget",
            paragraphs: paragraphs,
            limit: 6,
            maximumNewEmbeddings: 0,
            cache: cache
        )
        let sections = Set(result.hits.map {
            HybridRetriever.sectionKind($0.paragraph.section)
        })

        #expect(result.generatedEmbeddingCount == 0)
        #expect(result.cachedEmbeddingCount == 0)
        #expect(result.hits.count == 6)
        #expect(sections.isSuperset(of: ["abstract", "methods", "results", "discussion"]))
        #expect(result.hits.contains { $0.id == "i" })
    }

    @MainActor
    @Test func restoredHistoryUsesTheCurrentPagesCachedFineRankingState() {
        let works = (1...25).map { makeWork(id: "W\($0)", doi: "10.1000/\($0)") }
        var record = makeRecord(query: "polio", works: works, date: Date())
        record.snapshot.currentPage = 2
        record.snapshot.completedAIStage = .evidenceRanking
        record.snapshot.aiEvidenceLevels = Dictionary(
            uniqueKeysWithValues: works.enumerated().map { index, work in
                (work.id, index < 20 ? "AI 全文精排" : "AI 摘要精排")
            }
        )
        let store = SearchStore(restoreOnInit: false)

        store.restoreHistoryRecord(record)

        #expect(store.aiSecondRerankState == .completed(fullText: 0, abstractOnly: 5, retained: 25))
    }

    @MainActor
    @Test func restoredLocalFallbackKeepsTheFailureNoticeVisible() {
        let works = (1...5).map { makeWork(id: "W\($0)", doi: "10.1000/\($0)") }
        var record = makeRecord(query: "polio", works: works, date: Date())
        record.snapshot.aiEvidenceLevels = Dictionary(
            uniqueKeysWithValues: works.map { ($0.id, "本地摘要排序") }
        )
        let store = SearchStore(restoreOnInit: false)

        store.restoreHistoryRecord(record)

        #expect(
            store.aiSecondRerankState
                == .failed("第 1 页 AI 全文精排此前失败。当前使用本地全文证据排序。")
        )
    }

    @MainActor
    @Test func restoredLegacyRankingHidesObsoleteCoarseStatusText() {
        var record = makeRecord(query: "polio", works: [makeWork()], date: Date())
        record.snapshot.aiSearchNotice = "AI 粗排暂未返回，当前只显示临时候选"
        record.snapshot.searchTimingSummary = "首屏 45.4 秒 · 临时候选 · 证据初排 0.0 秒 · 全文补强 32.8 秒"
        let store = SearchStore(restoreOnInit: false)

        store.restoreHistoryRecord(record)

        #expect(store.aiSearchNotice == nil)
        #expect(store.searchTimingSummary == nil)
    }
}

private final class EvidenceRankingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedPrompts: [String] = []

    static var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedPrompts
    }

    static func reset() {
        lock.lock()
        storedPrompts = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.read)
        let prompt: String? = body.flatMap { body in
            guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = root["messages"] as? [[String: Any]],
                  let user = messages.last,
                  let content = user["content"] as? String else { return nil }
            return content
        }
        Self.lock.lock()
        if let prompt {
            Self.storedPrompts.append(prompt)
        }
        Self.lock.unlock()

        let ranking: String
        if prompt?.contains("conservative title/abstract eligibility triage") == true {
            ranking = #"{"decisions":[{"index":0,"disposition":"likely","directness":3,"confidence":"high"}]}"#
        } else if prompt?.contains("structured evidence card") == true {
            ranking = #"{"cards":[{"index":0,"population":"match","intervention_or_exposure":"match","comparator":"unclear","outcome":"unclear","context":"match","role":"primary","reports_effect_estimate":false,"reports_sample_size":true,"has_comparator_group":false,"reports_follow_up":false,"unique_contribution":false}]}"#
        } else {
            ranking = #"{"rankings":[{"index":0,"score":91,"relevant":true,"reason":"病因相关"}]}"#
        }
        let responseObject: [String: Any] = [
            "choices": [["message": ["content": ranking]]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: responseObject)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
