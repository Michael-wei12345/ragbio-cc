import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import UniformTypeIdentifiers

private let searchPerformanceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.local.RagBio",
    category: "SearchPerformance"
)

@MainActor
final class SearchStore: ObservableObject {
    @Published var query = ""
    @Published var sort: SearchSort = .relevance
    @Published var fromYearEnabled = false
    @Published var fromYear = Calendar.current.component(.year, from: Date()) - 5
    @Published var openAccessOnly = false
    @Published private(set) var works: [Work] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var currentPage = 1
    @Published private(set) var evidence: [Evidence] = []
    @Published var selection: Work.ID?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastQuery = ""
    @Published private(set) var fullTextState: FullTextLoadState = .idle
    @Published private(set) var fullTextDocument: FullTextDocument?
    @Published private(set) var passageHits: [PassageHit] = []
    @Published var passageQuery = ""
    @Published private(set) var aiFullTextDocuments: [String: FullTextDocument] = [:]
    @Published private(set) var fullTextReviewSummaries: [String: LiteratureReviewSummary] = [:]
    @Published private(set) var fullTextReviewSummaryInProgress: Set<String> = []
    @Published private(set) var fullTextReviewSummaryErrors: [String: String] = [:]
    @Published private(set) var articleSummaries: [String: String] = [:]
    @Published private(set) var articleSummaryInProgress: Set<String> = []
    @Published private(set) var articleSummaryErrors: [String: String] = [:]
    @Published private(set) var aiVisiblePageFullTextInProgress: Set<String> = []
    @Published private(set) var aiVisiblePageFullTextFailures: [String: String] = [:]
    @Published private(set) var translatedWorkIDs: Set<String> = []
    @Published var translatedTitles: [String: String] = [:]
    @Published var translatedAbstracts: [String: String] = [:]
    @Published var translatedEvidence: [String: String] = [:]
    @Published var translatedPassages: [String: String] = [:]
    @Published private(set) var lastAIPlan: AISearchPlan?
    @Published private(set) var aiRerankState: AIRerankState = .idle
    @Published private(set) var aiSecondRerankState: AISecondRerankState = .idle
    @Published private(set) var aiReasons: [String: String] = [:]
    @Published private(set) var aiScores: [String: Int] = [:]
    @Published private(set) var aiEvidenceLevels: [String: String] = [:]
    @Published private(set) var evidenceCards: [String: StructuredEvidenceCard] = [:]
    @Published private(set) var aiSearchNotice: String?
    @Published private(set) var pubMedNotice: String?
    @Published private(set) var searchTimingSummary: String?
    @Published var scanDecisions: [String: ScanDecisionRecord] = [:]
    @Published var currentEvidenceTable: EvidenceTable?
    @Published var decisionFilter: ScanDecisionFilter = .all {
        didSet {
            guard decisionFilter != oldValue, !isRestoringHistory else { return }
            scheduleCompletedStageSave()
        }
    }
    @Published var currentFieldScanReport: FieldScanReport?
    @Published var fieldSummary: FieldScanReport?
    @Published private(set) var isGeneratingFieldSummary = false
    @Published var fieldSummaryError: String?

    enum FieldSummaryScope {
        case topResults
        case marked
    }
    @Published var isGeneratingFieldScan = false
    @Published var fieldScanError: String?
    @Published private(set) var historySummaries: [SearchHistorySummary] = []
    @Published private(set) var currentHistoryID: UUID?
    @Published private(set) var currentHistoryRecord: SearchHistoryRecord?
    @Published private(set) var historyErrorMessage: String?
    @Published private(set) var isRefreshingHistory = false
    @Published private(set) var exportMessage: String?

    private let client: OpenAlexClient
    private let pubMedClient = PubMedClient()
    private let clinicalTrialsClient = ClinicalTrialsClient()
    private let fullTextService: FullTextService
    private let aiQueryPlanner: AIQueryPlanner
    private let historyStore: SearchHistoryStore
    private var aiRankedWorks: [Work] = []
    private var aiCandidateWorks: [Work] = []
    private var globalScoreFingerprint: String?
    private var searchGeneration = 0
    private var historyRevision = 0
    private var historyMutationToken = SearchHistoryMutationToken()
    private var historyRefreshFallbackRecord: SearchHistoryRecord?
    private var useMutationRevision = 0
    private var useMutationTask: Task<Void, Never>?
    private var isRestoringHistory = false
    let pageSize = 20
    /// Metadata/abstract discovery is intentionally much broader than evidence preparation.
    private let triagePoolLimit = 480
    private let aiCandidateLimit = 180
    private let fullTextPreparationLimit = 120
    private let openAlexCandidatePageSize = 200
    private let pubMedCandidatePageSize = 500
    private let candidateTriageBatchSize = 32
    private let candidateTriageMaxConcurrent = 6
    private let aiEvidenceBatchSize = 12
    private let evidenceAnalysisMaxConcurrent = 6
    private let fullTextMaxConcurrent = 12
    private let minimumGlobalRelevanceScore = 5
    nonisolated static let maximumNewEmbeddingsPerSearch = 500

    struct HistoryMutationContext: Equatable {
        let searchGeneration: Int
        let historyID: UUID?
    }

    init(
        client: OpenAlexClient = OpenAlexClient(),
        fullTextService: FullTextService = FullTextService(),
        aiQueryPlanner: AIQueryPlanner = AIQueryPlanner(),
        historyStore: SearchHistoryStore = SearchHistoryStore(),
        restoreOnInit: Bool = true
    ) {
        self.client = client
        self.fullTextService = fullTextService
        self.aiQueryPlanner = aiQueryPlanner
        self.historyStore = historyStore
        if restoreOnInit {
            Task { await loadInitialHistory() }
        }
    }

    func loadInitialHistory() async {
        let generation = searchGeneration
        do {
            try await historyStore.bootstrap()
            guard generation == searchGeneration else { return }
            let index = try await historyStore.loadIndex()
            guard generation == searchGeneration else { return }
            historySummaries = index.summaries
            guard let id = index.lastOpenedHistoryID else { return }
            await openHistory(id)
        } catch {
            guard generation == searchGeneration else { return }
            historyErrorMessage = error.localizedDescription
        }
    }

    func openHistory(_ id: UUID) async {
        invalidateAsyncWork()
        historyRefreshFallbackRecord = nil
        isLoading = false
        isRefreshingHistory = false
        let openGeneration = searchGeneration
        let mutationToken = historyMutationToken
        let record: SearchHistoryRecord
        do {
            record = try await historyStore.loadRecord(id: id)
        } catch {
            guard openGeneration == searchGeneration,
                  mutationToken.isValid else { return }
            clearVisibleSearch(invalidateAsync: false)
            historyErrorMessage = error.localizedDescription
            if let index = try? await historyStore.loadIndex() {
                guard openGeneration == searchGeneration,
                      mutationToken.isValid,
                      currentHistoryID == nil else { return }
                historySummaries = index.summaries
            }
            return
        }
        guard openGeneration == searchGeneration,
              mutationToken.isValid else { return }
        restoreHistoryRecord(record)
        do {
            let index = try await historyStore.setLastOpened(id)
            guard openGeneration == searchGeneration,
                  mutationToken.isValid,
                  currentHistoryID == id else { return }
            historySummaries = index.summaries
            historyErrorMessage = nil
        } catch {
            guard openGeneration == searchGeneration,
                  mutationToken.isValid,
                  currentHistoryID == id else { return }
            historyErrorMessage = error.localizedDescription
            if let index = try? await historyStore.loadIndex() {
                guard openGeneration == searchGeneration,
                      mutationToken.isValid,
                      currentHistoryID == id else { return }
                historySummaries = index.summaries
            }
        }
    }

    func deleteHistory(_ id: UUID) async {
        let deletingCurrent = currentHistoryID == id
        if deletingCurrent {
            invalidateAsyncWork()
        }
        let deleteGeneration = searchGeneration
        do {
            let index = try await historyStore.delete(id: id)
            guard deleteGeneration == searchGeneration else { return }
            historySummaries = index.summaries
            guard currentHistoryID == id else { return }
            clearVisibleSearch(invalidateAsync: false)
            historyErrorMessage = nil
        } catch {
            guard deleteGeneration == searchGeneration else { return }
            historyErrorMessage = error.localizedDescription
        }
    }

    func loadExportRecords(ids: Set<UUID>) async throws -> SearchHistoryExportDocument {
        var records: [SearchHistoryRecord] = []
        for id in ids {
            try Task.checkCancellation()
            let record = try await historyStore.loadRecord(id: id)
            if !record.useLedger.papers.isEmpty {
                records.append(record)
            }
            try Task.checkCancellation()
        }
        return SearchHistoryExportBuilder.make(records: records)
    }

    func presentExportStatus(_ document: SearchHistoryExportDocument) {
        exportMessage = "Exported \(document.urlCount) URLs. Skipped \(document.skippedPaperCount) papers without a usable URL."
    }

    func makeHistorySnapshot(displayQuery: String, revision: Int) -> SearchHistorySnapshot {
        SearchHistorySnapshot(
            revision: revision,
            displayQuery: displayQuery,
            retrievalQuery: lastQuery,
            sort: sort,
            fromYearEnabled: fromYearEnabled,
            fromYear: fromYear,
            openAccessOnly: openAccessOnly,
            allWorks: works,
            rankedWorks: aiRankedWorks,
            candidateWorks: aiCandidateWorks,
            totalCount: totalCount,
            currentPage: currentPage,
            selectedWorkID: selection,
            lastAIPlan: lastAIPlan,
            aiReasons: aiReasons,
            aiScores: aiScores,
            aiEvidenceLevels: aiEvidenceLevels,
            evidenceCards: evidenceCards,
            globalScoreFingerprint: globalScoreFingerprint,
            aiSearchNotice: aiSearchNotice,
            pubMedNotice: pubMedNotice,
            searchTimingSummary: searchTimingSummary,
            fullTextReviewSummaries: fullTextReviewSummaries,
            articleSummaries: articleSummaries,
            currentEvidenceTable: currentEvidenceTable,
            currentFieldScanReport: currentFieldScanReport,
            decisionFilter: decisionFilter,
            completedAIStage: SearchHistoryAIStage.completed(
                coarse: aiRerankState,
                evidence: aiSecondRerankState
            )
        )
    }

    func restoreHistoryRecord(_ record: SearchHistoryRecord) {
        isRestoringHistory = true
        defer { isRestoringHistory = false }
        let snapshot = record.snapshot
        query = record.displayQuery
        sort = snapshot.sort
        fromYearEnabled = snapshot.fromYearEnabled
        fromYear = snapshot.fromYear
        openAccessOnly = snapshot.openAccessOnly
        works = snapshot.allWorks
        aiRankedWorks = snapshot.rankedWorks
        aiCandidateWorks = snapshot.candidateWorks
        totalCount = snapshot.totalCount
        currentPage = snapshot.currentPage
        selection = snapshot.selectedWorkID
        lastQuery = snapshot.retrievalQuery
        lastAIPlan = snapshot.lastAIPlan
        aiReasons = snapshot.aiReasons
        aiScores = snapshot.aiScores
        aiEvidenceLevels = snapshot.aiEvidenceLevels
        evidenceCards = snapshot.evidenceCards
        globalScoreFingerprint = snapshot.globalScoreFingerprint
        aiSearchNotice = snapshot.aiSearchNotice?.contains("粗排") == true
            ? nil
            : snapshot.aiSearchNotice
        pubMedNotice = snapshot.pubMedNotice
        if let timing = snapshot.searchTimingSummary,
           timing.contains("临时候选")
            || timing.contains("证据初排")
            || timing.contains("全文补强") {
            searchTimingSummary = nil
        } else {
            searchTimingSummary = snapshot.searchTimingSummary
        }
        fullTextReviewSummaries = snapshot.fullTextReviewSummaries
        articleSummaries = snapshot.articleSummaries
        currentEvidenceTable = snapshot.currentEvidenceTable
        currentFieldScanReport = snapshot.currentFieldScanReport
        currentHistoryID = record.id
        currentHistoryRecord = record
        historyRevision = snapshot.revision
        decisionFilter = snapshot.decisionFilter
        applyUseLedgerToVisibleWorks(record.useLedger)
        evidence = EvidenceExtractor.extract(query: snapshot.retrievalQuery, works: works)
        fullTextState = .idle
        fullTextDocument = nil
        passageHits = []
        passageQuery = snapshot.retrievalQuery
        isLoading = false
        errorMessage = nil
        isGeneratingFieldScan = false
        fieldScanError = nil
        fullTextReviewSummaryInProgress = []
        fullTextReviewSummaryErrors = [:]
        aiVisiblePageFullTextInProgress = []
        aiVisiblePageFullTextFailures = [:]
        let candidates = max(snapshot.totalCount, snapshot.rankedWorks.count)
        switch snapshot.completedAIStage ?? .localCandidates {
        case .localCandidates:
            aiRerankState = .localReady(candidates: candidates)
            aiSecondRerankState = .idle
        case .coarseRanking:
            aiRerankState = .completed(
                candidates: candidates,
                retained: snapshot.rankedWorks.count
            )
            aiSecondRerankState = .idle
        case .evidenceRanking:
            aiRerankState = .completed(
                candidates: candidates,
                retained: snapshot.rankedWorks.count
            )
            aiSecondRerankState = .idle
        case .globalEvidenceRanking:
            aiRerankState = .completed(
                candidates: max(snapshot.candidateWorks.count, candidates),
                retained: snapshot.rankedWorks.count
            )
            let fullText = snapshot.rankedWorks.filter {
                snapshot.aiEvidenceLevels[$0.id]?.hasPrefix("全文") == true
            }.count
            aiSecondRerankState = .completed(
                fullText: fullText,
                abstractOnly: snapshot.rankedWorks.count - fullText,
                retained: snapshot.rankedWorks.count
            )
        }
        if case .idle = aiSecondRerankState {
            let start = max(0, (currentPage - 1) * pageSize)
            let end = min(start + pageSize, snapshot.rankedWorks.count)
            if start < end {
                let pageLevels = snapshot.rankedWorks[start..<end].compactMap {
                    snapshot.aiEvidenceLevels[$0.id]
                }
                if pageLevels.count == end - start,
                   pageLevels.allSatisfy({ $0.hasPrefix("本地") }) {
                    aiSecondRerankState = .failed(
                        "第 \(currentPage) 页 AI 全文精排此前失败。当前使用本地全文证据排序。"
                    )
                } else if pageLevels.count == end - start,
                          pageLevels.allSatisfy({
                              $0.hasPrefix("AI 全文精排") || $0.hasPrefix("AI 摘要精排")
                          }) {
                    let fullText = pageLevels.filter { $0.contains("全文") }.count
                    aiSecondRerankState = .completed(
                        fullText: fullText,
                        abstractOnly: pageLevels.count - fullText,
                        retained: snapshot.rankedWorks.count
                    )
                }
            }
        }
    }

    func captureHistoryMutationContext() -> HistoryMutationContext {
        HistoryMutationContext(
            searchGeneration: searchGeneration,
            historyID: currentHistoryID
        )
    }

    func isCurrentHistoryMutationContext(_ context: HistoryMutationContext) -> Bool {
        context.searchGeneration == searchGeneration
            && context.historyID == currentHistoryID
    }

    private func invalidateAsyncWork() {
        advanceSearchGeneration()
    }

    private func advanceSearchGeneration() {
        historyMutationToken.invalidate()
        historyMutationToken = SearchHistoryMutationToken()
        searchGeneration &+= 1
    }

    @discardableResult
    func beginHistorySearch(displayQuery: String) async -> Int {
        let activeFilters = (
            sort: sort,
            fromYearEnabled: fromYearEnabled,
            fromYear: fromYear,
            openAccessOnly: openAccessOnly
        )
        advanceSearchGeneration()
        let generation = searchGeneration
        let normalized = SearchQueryIdentity.normalize(displayQuery)
        let prior: SearchHistoryRecord?
        if currentHistoryRecord?.normalizedQuery == normalized {
            prior = currentHistoryRecord
        } else {
            prior = try? await historyStore.record(normalizedQuery: normalized)
        }
        guard generation == searchGeneration else { return generation }
        historyRefreshFallbackRecord = prior
        if let prior {
            restoreHistoryRecord(prior)
            sort = activeFilters.sort
            fromYearEnabled = activeFilters.fromYearEnabled
            fromYear = activeFilters.fromYear
            openAccessOnly = activeFilters.openAccessOnly
            query = displayQuery
            isRefreshingHistory = true
        } else {
            query = displayQuery
            clearVisibleSearch(invalidateAsync: false, clearQuery: false)
        }
        errorMessage = nil
        historyErrorMessage = nil
        return generation
    }

    func isCurrentSearchGeneration(_ generation: Int) -> Bool {
        generation == searchGeneration
    }

    private func finishHistorySearchFailure(
        generation: Int,
        message: String?,
        cancelled: Bool = false
    ) {
        guard generation == searchGeneration else { return }
        isLoading = false
        isRefreshingHistory = false
        historyRefreshFallbackRecord = nil
        if !cancelled { errorMessage = message }
    }

    private func clearVisibleSearch(
        invalidateAsync: Bool = true,
        clearQuery: Bool = true
    ) {
        if invalidateAsync {
            invalidateAsyncWork()
        }
        if clearQuery {
            query = ""
        }
        works = []
        aiRankedWorks = []
        aiCandidateWorks = []
        totalCount = 0
        currentPage = 1
        selection = nil
        lastQuery = ""
        evidence = []
        isLoading = false
        errorMessage = nil
        lastAIPlan = nil
        aiRerankState = .idle
        aiSecondRerankState = .idle
        aiReasons = [:]
        aiScores = [:]
        aiEvidenceLevels = [:]
        evidenceCards = [:]
        globalScoreFingerprint = nil
        aiSearchNotice = nil
        pubMedNotice = nil
        searchTimingSummary = nil
        fullTextState = .idle
        fullTextDocument = nil
        passageHits = []
        passageQuery = ""
        aiFullTextDocuments = [:]
        fullTextReviewSummaries = [:]
        fullTextReviewSummaryInProgress = []
        fullTextReviewSummaryErrors = [:]
        articleSummaries = [:]
        articleSummaryInProgress = []
        articleSummaryErrors = [:]
        aiVisiblePageFullTextInProgress = []
        aiVisiblePageFullTextFailures = [:]
        translatedWorkIDs = []
        translatedTitles = [:]
        translatedAbstracts = [:]
        translatedEvidence = [:]
        translatedPassages = [:]
        scanDecisions = [:]
        currentEvidenceTable = nil
        currentFieldScanReport = nil
        fieldSummary = nil
        isGeneratingFieldScan = false
        isGeneratingFieldSummary = false
        fieldScanError = nil
        fieldSummaryError = nil
        currentHistoryID = nil
        currentHistoryRecord = nil
        historyRefreshFallbackRecord = nil
        historyRevision = 0
        isRefreshingHistory = false
        decisionFilter = .all
    }

    private func applyUseLedgerToVisibleWorks(_ ledger: UseLedger) {
        var decisions: [String: ScanDecisionRecord] = [:]
        for (paper, work) in zip(ledger.papers, useWorks) {
            decisions[work.id] = ScanDecisionRecord(
                workID: work.id,
                decision: .use,
                note: nil,
                updatedAt: paper.selectedAt
            )
        }
        scanDecisions = decisions
    }

    private func publishStageHistorySummaries(_ incoming: [SearchHistorySummary]) {
        let useCounts = Dictionary(
            uniqueKeysWithValues: historySummaries.map { ($0.id, $0.useCount) }
        )
        historySummaries = incoming.map { summary in
            guard let useCount = useCounts[summary.id] else { return summary }
            var merged = summary
            merged.useCount = useCount
            return merged
        }
    }

    private func publishUseHistorySummaries(_ incoming: [SearchHistorySummary]) {
        let useCounts = Dictionary(
            uniqueKeysWithValues: incoming.map { ($0.id, $0.useCount) }
        )
        var seen = Set(historySummaries.map(\.id))
        historySummaries = historySummaries.map { summary in
            guard let useCount = useCounts[summary.id] else { return summary }
            var merged = summary
            merged.useCount = useCount
            return merged
        }
        historySummaries.append(contentsOf: incoming.filter { seen.insert($0.id).inserted })
    }

    private func scheduleCompletedStageSave() {
        guard let record = currentHistoryRecord else { return }
        let context = captureHistoryMutationContext()
        historyRevision &+= 1
        let snapshot = makeHistorySnapshot(
            displayQuery: record.displayQuery,
            revision: historyRevision
        )
        Task { [weak self] in
            guard let self,
                  self.isCurrentHistoryMutationContext(context) else { return }
            await self.persistCurrentStage(
                snapshot,
                expectedGeneration: context.searchGeneration
            )
        }
    }

    func commitFirstUsableHistoryStage(
        displayQuery: String,
        startedAt: Date,
        generation: Int
    ) async {
        guard generation == searchGeneration, !aiRankedWorks.isEmpty else { return }
        let normalized = SearchQueryIdentity.normalize(displayQuery)
        let mutationToken = historyMutationToken
        let snapshot = makeHistorySnapshot(
            displayQuery: displayQuery,
            revision: historyRevision + 1
        )
        do {
            let result = try await historyStore.saveFirstUsableStage(
                displayQuery: displayQuery,
                normalizedQuery: normalized,
                startedAt: startedAt,
                completedAt: Date(),
                snapshot: snapshot,
                mutationToken: mutationToken
            )
            guard generation == searchGeneration,
                  mutationToken.isValid else { return }
            historyRevision = result.record.snapshot.revision
            currentHistoryID = result.record.id
            let publishedRecord: SearchHistoryRecord
            if let current = currentHistoryRecord,
               current.id == result.record.id {
                var merged = result.record
                var newestLedger = current.useLedger
                newestLedger.reconcile(
                    with: result.record.snapshot.rankedWorks + result.record.snapshot.allWorks
                )
                merged.useLedger = newestLedger
                currentHistoryRecord = merged
                publishedRecord = merged
            } else {
                currentHistoryRecord = result.record
                publishedRecord = result.record
            }
            publishStageHistorySummaries(result.index.summaries)
            if let index = historySummaries.firstIndex(where: { $0.id == publishedRecord.id }) {
                historySummaries[index].useCount = publishedRecord.useLedger.papers.count
            }
            isRefreshingHistory = false
            historyRefreshFallbackRecord = nil
            applyUseLedgerToVisibleWorks(publishedRecord.useLedger)
        } catch {
            guard generation == searchGeneration,
                  mutationToken.isValid else { return }
            let authoritative = try? await historyStore.record(
                normalizedQuery: normalized
            )
            guard generation == searchGeneration,
                  mutationToken.isValid else { return }
            if let authoritative {
                restoreHistoryRecord(authoritative)
            } else if let old = historyRefreshFallbackRecord {
                restoreHistoryRecord(old)
            }
            historyRefreshFallbackRecord = nil
            historyErrorMessage = "Search completed, but history could not be saved."
            isRefreshingHistory = false
        }
    }

    func persistCurrentStage(
        _ snapshot: SearchHistorySnapshot,
        expectedGeneration: Int
    ) async {
        guard expectedGeneration == searchGeneration,
              let historyID = currentHistoryID else { return }
        let mutationToken = historyMutationToken
        do {
            let record = try await historyStore.updateSnapshot(
                historyID: historyID,
                snapshot: snapshot,
                mutationToken: mutationToken
            )
            guard expectedGeneration == searchGeneration,
                  mutationToken.isValid else { return }
            let index = try await historyStore.loadIndex()
            guard expectedGeneration == searchGeneration,
                  mutationToken.isValid else { return }
            if var current = currentHistoryRecord,
               current.id == record.id,
               record.snapshot.revision >= current.snapshot.revision {
                current.snapshot = record.snapshot
                currentHistoryRecord = current
            }
            publishStageHistorySummaries(index.summaries)
        } catch {
            guard expectedGeneration == searchGeneration,
                  mutationToken.isValid else { return }
            historyErrorMessage = "Search completed, but history could not be saved."
        }
    }

    var selectedWork: Work? {
        guard let selection else { return nil }
        if let current = (aiRankedWorks + works).first(where: { $0.id == selection }) {
            return current
        }
        guard let ledger = currentHistoryRecord?.useLedger,
              let selectedPaper = ledger.papers.first(where: {
                  $0.work.id == selection
              }) else { return nil }
        return useWorks.first {
            selectedPaper.identity.matches(PaperIdentity(work: $0))
        }
    }

    var useWorks: [Work] {
        guard let ledger = currentHistoryRecord?.useLedger else { return [] }
        let refreshed = aiRankedWorks + works
        var projected: [Work] = []
        for paper in ledger.papers {
            let work = refreshed.first {
                paper.identity.matches(PaperIdentity(work: $0))
            } ?? paper.work
            let identity = PaperIdentity(work: work)
            guard !projected.contains(where: {
                $0.id == work.id || PaperIdentity(work: $0).matches(identity)
            }) else { continue }
            projected.append(work)
        }
        return projected
    }

    var filteredWorks: [Work] {
        switch decisionFilter {
        case .candidate:
            return works.filter { $0.nonPrimaryPublicationKind == nil }
        case .use:
            return useWorks.filter(matchesActiveResultFilters)
        default:
            return works
        }
    }

    func setOpenAccessFilter(_ enabled: Bool) {
        guard openAccessOnly != enabled else { return }
        openAccessOnly = enabled
        applyActiveResultFilters()
    }

    func setFromYearFilterEnabled(_ enabled: Bool) {
        guard fromYearEnabled != enabled else { return }
        fromYearEnabled = enabled
        applyActiveResultFilters()
    }

    func setFromYearFilter(_ year: Int) {
        guard fromYear != year else { return }
        fromYear = year
        if fromYearEnabled {
            applyActiveResultFilters()
        }
    }

    var evidenceTableMarkdown: String? {
        currentEvidenceTable.map(EvidenceTableService.markdown)
    }

    var evidenceTableCSV: String? {
        currentEvidenceTable.map(EvidenceTableService.csv)
    }

    func availableFullTextDocument(for work: Work) -> FullTextDocument? {
        if let document = fullTextDocument,
           document.workID == work.id,
           document.source.isFullText,
           Self.fullTextDocument(document, matches: work) {
            return document
        }
        if let document = aiFullTextDocuments[work.id],
           document.source.isFullText,
           Self.fullTextDocument(document, matches: work) {
            return document
        }
        return nil
    }

    func literatureReviewSourceExcerpts(
        for work: Work,
        summary: LiteratureReviewSummary,
        limit: Int = 6
    ) -> [LiteratureReviewSourceExcerpt] {
        guard let document = availableFullTextDocument(for: work) else { return [] }
        return Array(
            LiteratureReviewCitationBuilder.make(
                summary: summary,
                document: document
            ).prefix(limit)
        )
    }

    func focusLiteratureReviewSource(
        _ excerpt: LiteratureReviewSourceExcerpt,
        for work: Work
    ) {
        guard let document = availableFullTextDocument(for: work) else { return }
        selection = work.id
        fullTextDocument = document
        fullTextState = .loaded
        let query = Self.focusQuery(from: excerpt.text)
        passageQuery = query

        let ranked = HybridRetriever.search(
            query: query,
            paragraphs: document.paragraphs
        )
        guard let sourceParagraph = document.paragraphs.first(where: { $0.id == excerpt.paragraphID }) else {
            passageHits = ranked
            return
        }

        let exactHit = PassageHit(
            id: sourceParagraph.id,
            paragraph: sourceParagraph,
            score: max(0.99, ranked.first?.score ?? 0),
            matchedTerms: []
        )
        passageHits = [exactHit] + ranked.filter { $0.id != sourceParagraph.id }
    }

    func setScanDecision(_ decision: ScanDecision, for work: Work) {
        guard let historyID = currentHistoryID else { return }
        let previous = useMutationTask
        useMutationTask = Task { [weak self] in
            await previous?.value
            await self?.setUse(
                decision == .use,
                for: work,
                expectedHistoryID: historyID
            )
        }
    }

    func clearScanDecision(for work: Work) {
        setScanDecision(.unreviewed, for: work)
    }

    func clearAllUse() {
        guard let historyID = currentHistoryID else { return }
        let previous = useMutationTask
        useMutationTask = Task { [weak self] in
            await previous?.value
            await self?.clearAllUse(expectedHistoryID: historyID)
        }
    }

    func waitForPendingUseMutations() async {
        await useMutationTask?.value
    }

    func setUse(_ isUsed: Bool, for work: Work) async {
        guard let historyID = currentHistoryID else { return }
        await setUse(isUsed, for: work, expectedHistoryID: historyID)
    }

    private func setUse(
        _ isUsed: Bool,
        for work: Work,
        expectedHistoryID historyID: UUID
    ) async {
        guard currentHistoryID == historyID,
              let previous = currentHistoryRecord else { return }
        useMutationRevision &+= 1
        let revision = useMutationRevision
        let context = captureHistoryMutationContext()
        var optimistic = previous
        if isUsed {
            optimistic.useLedger.mark(work)
        } else {
            optimistic.useLedger.remove(work)
        }
        currentHistoryRecord = optimistic
        applyUseLedgerToVisibleWorks(optimistic.useLedger)
        currentEvidenceTable = nil
        currentFieldScanReport = nil
        do {
            let record = try await historyStore.setUse(
                historyID: historyID,
                work: work,
                isUsed: isUsed
            )
            guard revision == useMutationRevision,
                  isCurrentHistoryMutationContext(context) else { return }
            let index = try await historyStore.loadIndex()
            guard revision == useMutationRevision,
                  isCurrentHistoryMutationContext(context) else { return }
            if var current = currentHistoryRecord,
               current.id == record.id {
                current.useLedger = record.useLedger
                currentHistoryRecord = current
            }
            publishUseHistorySummaries(index.summaries)
            applyUseLedgerToVisibleWorks(record.useLedger)
            historyErrorMessage = nil
        } catch {
            guard revision == useMutationRevision,
                  isCurrentHistoryMutationContext(context) else { return }
            if var current = currentHistoryRecord,
               current.id == previous.id {
                current.useLedger = previous.useLedger
                currentHistoryRecord = current
            }
            applyUseLedgerToVisibleWorks(previous.useLedger)
            historyErrorMessage = "Use could not be saved. Your previous selection was restored."
        }
    }

    private func clearAllUse(expectedHistoryID historyID: UUID) async {
        guard currentHistoryID == historyID,
              let previous = currentHistoryRecord,
              !previous.useLedger.papers.isEmpty else { return }
        useMutationRevision &+= 1
        let revision = useMutationRevision
        let context = captureHistoryMutationContext()
        var optimistic = previous
        optimistic.useLedger.removeAll()
        currentHistoryRecord = optimistic
        applyUseLedgerToVisibleWorks(optimistic.useLedger)
        currentEvidenceTable = nil
        currentFieldScanReport = nil
        do {
            let record = try await historyStore.clearUse(historyID: historyID)
            guard revision == useMutationRevision,
                  isCurrentHistoryMutationContext(context) else { return }
            let index = try await historyStore.loadIndex()
            guard revision == useMutationRevision,
                  isCurrentHistoryMutationContext(context) else { return }
            currentHistoryRecord = record
            publishUseHistorySummaries(index.summaries)
            applyUseLedgerToVisibleWorks(record.useLedger)
            historyErrorMessage = nil
        } catch {
            guard revision == useMutationRevision,
                  isCurrentHistoryMutationContext(context) else { return }
            currentHistoryRecord = previous
            applyUseLedgerToVisibleWorks(previous.useLedger)
            historyErrorMessage = "Use selections could not be cleared. Your previous selections were restored."
        }
    }

    func decision(for work: Work) -> ScanDecision {
        currentHistoryRecord?.useLedger.contains(work) == true ? .use : .unreviewed
    }

    func generateEvidenceTable() {
        let table = EvidenceTableService.make(
            input: EvidenceTableService.Input(
                query: lastQuery.isEmpty ? query : lastQuery,
                rankedWorks: evidenceTableSourceWorks(),
                scanDecisions: scanDecisions,
                accessStatusByWorkID: evidenceAccessStatuses(),
                aiScores: aiScores,
                aiReasons: aiReasons,
                aiEvidenceLevels: aiEvidenceLevels,
                summaries: fullTextReviewSummaries,
                sourceRefsByWorkID: evidenceSourceRefs()
            )
        )
        currentEvidenceTable = table
        currentFieldScanReport = nil
        fieldScanError = nil
        scheduleCompletedStageSave()
    }

    func exportEvidenceTableMarkdown() {
        if currentEvidenceTable == nil {
            generateEvidenceTable()
        }
        guard let markdown = evidenceTableMarkdown else { return }
        exportText(
            markdown,
            suggestedName: "RagBio-EvidenceTable-\(safeFilename(lastQuery)).md",
            message: "导出当前 research scan 的 Evidence Table Markdown"
        )
    }

    func exportEvidenceTableCSV() {
        if currentEvidenceTable == nil {
            generateEvidenceTable()
        }
        guard let csv = evidenceTableCSV else { return }
        exportText(
            csv,
            suggestedName: "RagBio-EvidenceTable-\(safeFilename(lastQuery)).csv",
            message: "导出当前 research scan 的 Evidence Table CSV"
        )
    }

    func generateFieldScanReport() async {
        if currentEvidenceTable == nil {
            generateEvidenceTable()
        }
        guard let table = currentEvidenceTable else { return }
        let configuration = AIProviderConfiguration.load(activeAIProvider)
        guard configuration.isConfigured else {
            fieldScanError = AIPlannerError.notConfigured(configuration.provider)
                .localizedDescription
            return
        }
        let generation = searchGeneration
        isGeneratingFieldScan = true
        fieldScanError = nil
        defer { isGeneratingFieldScan = false }
        do {
            let report = try await FieldScanService().generate(
                table: table,
                normalizedQuery: lastAIPlan?.searchQuery,
                configuration: configuration
            )
            guard generation == searchGeneration else { return }
            currentFieldScanReport = report
            scheduleCompletedStageSave()
        } catch {
            guard generation == searchGeneration else { return }
            fieldScanError = error.localizedDescription
        }
    }

    var hasMarkedUseWorks: Bool {
        currentHistoryRecord?.useLedger.papers.isEmpty == false
    }

    var fullTextSummaryCount: Int {
        fullTextReviewSummaries.count
    }

    var workTitleLookup: [String: String] {
        var lookup: [String: String] = [:]
        for work in aiRankedWorks + works + useWorks { lookup[work.id] = work.title }
        return lookup
    }

    var workURLLookup: [String: URL] {
        var lookup: [String: URL] = [:]
        for work in aiRankedWorks + works + useWorks where lookup[work.id] == nil {
            if let url = work.landingPageURL { lookup[work.id] = url }
        }
        return lookup
    }

    /// Generates a field-level summary (reusing the Field Scan generator + work_id validation)
    /// from either the top current results or the papers the user marked Use.
    func generateFieldSummary(scope: FieldSummaryScope) async {
        let selected = fieldSummarySourceWorks(scope: scope)
        guard !selected.isEmpty else {
            switch scope {
            case .marked:
                fieldSummaryError = "还没有标记 Use 的论文。先给几篇点 Use，再生成。"
            case .topResults:
                fieldSummaryError = "当前没有可用于生成的检索结果。"
            }
            return
        }
        let configuration = AIProviderConfiguration.load(activeAIProvider)
        guard configuration.isConfigured else {
            fieldSummaryError = AIPlannerError.notConfigured(configuration.provider)
                .localizedDescription
            return
        }
        let input = EvidenceTableService.Input(
            query: lastQuery.isEmpty ? query : lastQuery,
            rankedWorks: selected,
            scanDecisions: scanDecisions,
            accessStatusByWorkID: evidenceAccessStatuses(),
            aiScores: aiScores,
            aiReasons: aiReasons,
            aiEvidenceLevels: aiEvidenceLevels,
            summaries: fullTextReviewSummaries,
            sourceRefsByWorkID: evidenceSourceRefs()
        )
        let rows = EvidenceTableService.rows(for: selected, input: input)
        let generation = searchGeneration
        isGeneratingFieldSummary = true
        fieldSummaryError = nil
        defer { isGeneratingFieldSummary = false }
        do {
            let report = try await FieldScanService().generate(
                rows: rows,
                query: input.query,
                normalizedQuery: lastAIPlan?.searchQuery,
                configuration: configuration
            )
            guard generation == searchGeneration else { return }
            fieldSummary = report
        } catch {
            guard generation == searchGeneration else { return }
            fieldSummaryError = error.localizedDescription
        }
    }

    func fieldSummarySourceWorks(scope: FieldSummaryScope) -> [Work] {
        switch scope {
        case .topResults:
            return Array((aiRankedWorks.isEmpty ? works : aiRankedWorks).prefix(30))
        case .marked:
            return useWorks
        }
    }

    func exportFieldScanMarkdown() {
        guard let report = currentFieldScanReport else { return }
        exportText(
            fieldScanMarkdown(report),
            suggestedName: "RagBio-FieldScan-\(safeFilename(report.query)).md",
            message: "导出 Field Scan Markdown"
        )
    }

    var abstractCoverage: Int {
        works.filter { $0.abstractText != nil }.count
    }

    var completedGlobalRankingWithNoResults: Bool {
        guard !aiCandidateWorks.isEmpty, aiRankedWorks.isEmpty else { return false }
        if case .completed = aiSecondRerankState { return true }
        return false
    }

    var completedSearchFilteredToNoResults: Bool {
        !isLoading
            && !aiRankedWorks.isEmpty
            && works.isEmpty
            && (openAccessOnly || fromYearEnabled)
    }

    var totalPages: Int {
        min(500, max(1, Int(ceil(Double(totalCount) / Double(pageSize)))))
    }

    var canGoToPreviousPage: Bool {
        currentPage > 1 && !isLoading
    }

    var canGoToNextPage: Bool {
        currentPage < totalPages && !isLoading
    }

    var visibleResultRange: String {
        guard !works.isEmpty else { return "0" }
        let start = (currentPage - 1) * pageSize + 1
        return "\(start)–\(start + works.count - 1)"
    }

    func passageTranslationKey(workID: String, passageID: String) -> String {
        "\(workID)|\(passageID)"
    }

    func translatedPassage(workID: String, passageID: String) -> String? {
        translatedPassages[passageTranslationKey(workID: workID, passageID: passageID)]
    }

    func isTranslationVisible(for workID: String) -> Bool {
        translatedWorkIDs.contains(workID)
    }

    func setTranslationVisible(_ visible: Bool, for workID: String) {
        if visible {
            translatedWorkIDs.insert(workID)
        } else {
            translatedWorkIDs.remove(workID)
        }
    }

    func search() async {
        let displayQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayQuery.isEmpty else { return }
        let generation = await beginHistorySearch(displayQuery: displayQuery)
        guard generation == searchGeneration else { return }
        let searchStartedAt = Date()

        let provider = activeAIProvider
        let configuration = AIProviderConfiguration.load(provider)
        guard configuration.isConfigured else {
            finishHistorySearchFailure(
                generation: generation,
                message: AIPlannerError.notConfigured(provider).localizedDescription
            )
            return
        }

        isLoading = true
        aiRerankState = .idle
        aiSecondRerankState = .idle
        do {
            let planningStartedAt = Date()
            let currentFromYear = fromYearEnabled ? fromYear : nil
            let generatedPlan = try await planAISearchWithSoftTimeout(
                description: displayQuery,
                configuration: configuration,
                currentSort: sort,
                currentFromYear: currentFromYear,
                currentOpenAccessOnly: openAccessOnly,
                timeoutSeconds: 22
            )
            let plan = Self.enforcingSearchControls(
                on: generatedPlan,
                fromYear: currentFromYear,
                openAccessOnly: openAccessOnly
            )
            try ensureSearchIsActive(generation)
            let planningSeconds = elapsedSeconds(since: planningStartedAt)

            aiRerankState = .fetchingCandidates
            let apiKey = CredentialStore.string(for: .openAlexAPIKey)
            let candidateStartedAt = Date()
            let candidateResult = try await fetchAICandidates(
                plan: plan,
                originalRequest: displayQuery,
                configuration: configuration,
                apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? nil
                    : apiKey
            )
            try ensureSearchIsActive(generation)
            let candidates = candidateResult.works
            let candidateSeconds = elapsedSeconds(since: candidateStartedAt)

            lastAIPlan = plan
            sort = plan.sort
            openAccessOnly = plan.openAccessOnly
            if let year = plan.fromYear {
                fromYearEnabled = true
                fromYear = min(
                    Calendar.current.component(.year, from: Date()),
                    max(1900, year)
                )
            } else {
                fromYearEnabled = false
            }
            currentEvidenceTable = nil
            currentFieldScanReport = nil
            fieldSummary = nil
            fieldScanError = nil
            fieldSummaryError = nil
            aiSearchNotice = candidateResult.aiNotice
            pubMedNotice = candidateResult.pubMedNotice
            aiFullTextDocuments = [:]
            fullTextReviewSummaries = [:]
            fullTextReviewSummaryInProgress = []
            fullTextReviewSummaryErrors = [:]
            articleSummaries = [:]
            articleSummaryInProgress = []
            articleSummaryErrors = [:]
            aiVisiblePageFullTextInProgress = []
            aiVisiblePageFullTextFailures = [:]
            evidenceCards = [:]
            globalScoreFingerprint = nil
            aiCandidateWorks = candidates
            aiRankedWorks = candidates
            lastQuery = plan.searchQuery
            totalCount = candidates.count
            currentPage = 1
            aiRerankState = .localReady(candidates: candidates.count)
            do {
                let ranking = try await rankAllCandidatesWithEvidence(
                    candidates,
                    originalRequest: displayQuery,
                    retrievalQuery: plan.searchQuery,
                    plan: plan,
                    configuration: configuration,
                    generation: generation
                )
                try ensureSearchIsActive(generation)
                searchTimingSummary = ranking.calibrated
                    ? "全局精排 \(ranking.seconds) 秒 · AI 理解 \(planningSeconds) 秒 · 候选获取 \(candidateSeconds) 秒"
                    : "本地证据排序 \(ranking.seconds) 秒 · 统一评分未完成 · 可重试"
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try ensureSearchIsActive(generation)
                applyGlobalRankingFailure(candidates: candidates, message: error.localizedDescription)
                searchTimingSummary = "全局精排未完成 · AI 理解 \(planningSeconds) 秒 · 候选获取 \(candidateSeconds) 秒"
            }
            isLoading = false
            showAIPage(1, persistStage: false)
            await commitFirstUsableHistoryStage(
                displayQuery: displayQuery,
                startedAt: searchStartedAt,
                generation: generation
            )
        } catch is CancellationError {
            guard generation == searchGeneration else { return }
            aiRerankState = .idle
            finishHistorySearchFailure(
                generation: generation,
                message: nil,
                cancelled: true
            )
        } catch {
            guard generation == searchGeneration else { return }
            aiRerankState = .idle
            finishHistorySearchFailure(
                generation: generation,
                message: error.localizedDescription
            )
        }
    }

    private func rankAllCandidatesWithEvidence(
        _ candidates: [Work],
        originalRequest: String,
        retrievalQuery: String,
        plan: AISearchPlan,
        configuration: AIProviderConfiguration,
        generation: Int
    ) async throws -> (seconds: String, calibrated: Bool) {
        guard !candidates.isEmpty else { return ("0.0", true) }
        let startedAt = Date()
        let apiKey = CredentialStore.string(for: .openAlexAPIKey)
        let semanticScholarAPIKey = CredentialStore.string(for: .semanticScholarAPIKey)
        let contactEmail = UserDefaults.standard.string(forKey: SettingsKeys.contactEmail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let service = fullTextService
        var documentsByID = aiFullTextDocuments
        let fullTextCandidates = Self.fullTextPreparationCandidates(
            candidates,
            limit: fullTextPreparationLimit
        )
        let pending = fullTextCandidates.filter { documentsByID[$0.id] == nil }
        var completed = candidates.count - pending.count
        aiSecondRerankState = .refiningFullText(completed: completed, total: candidates.count)

        await withTaskGroup(of: (Work, FullTextDocument?).self) { group in
            var next = 0
            func enqueue(_ work: Work) {
                group.addTask {
                    let document = await Self.loadFullTextWithSoftTimeout(
                        service: service,
                        work: work,
                        apiKey: apiKey,
                        contactEmail: contactEmail,
                        semanticScholarAPIKey: semanticScholarAPIKey,
                        seconds: 6
                    )
                    return (work, document)
                }
            }
            while next < min(fullTextMaxConcurrent, pending.count) {
                enqueue(pending[next])
                next += 1
            }
            for await (work, document) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                if let document,
                   document.source.isFullText,
                   Self.fullTextDocument(document, matches: work) {
                    documentsByID[work.id] = document
                } else {
                    aiVisiblePageFullTextFailures[work.id] =
                        "No accessible full text was found automatically; ranking used the abstract."
                }
                completed += 1
                aiSecondRerankState = .refiningFullText(
                    completed: completed,
                    total: candidates.count
                )
                if next < pending.count {
                    enqueue(pending[next])
                    next += 1
                }
            }
        }
        try ensureSearchIsActive(generation)
        aiFullTextDocuments = documentsByID
        searchPerformanceLogger.info(
            "Full-text preparation finished candidates=\(candidates.count, privacy: .public) documents=\(documentsByID.count, privacy: .public) seconds=\(Date().timeIntervalSince(startedAt), privacy: .public)"
        )

        let evidenceQuery = Self.evidenceRetrievalQuery(
            originalRequest: originalRequest,
            retrievalQuery: retrievalQuery
        )
        let retrievalStartedAt = Date()
        aiSecondRerankState = .fetchingEvidence(completed: 0, total: candidates.count)
        let preparedQuery = await Task.detached(priority: .utility) {
            HybridRetriever.prepare(query: evidenceQuery)
        }.value
        var inputs: [AIEvidenceRankingInput] = []
        var generatedEmbeddingCount = 0
        let fullTextDocumentCount = candidates.reduce(into: 0) { count, work in
            if documentsByID[work.id]?.source.isFullText == true { count += 1 }
        }
        let maximumNewEmbeddingsPerDocument = Self.newEmbeddingAllowance(
            fullTextDocumentCount: fullTextDocumentCount
        )
        let preparationBatchSize = 10
        for start in stride(from: 0, to: candidates.count, by: preparationBatchSize) {
            try ensureSearchIsActive(generation)
            let end = min(start + preparationBatchSize, candidates.count)
            let batchCandidates = Array(candidates[start..<end])
            let batchInputs = await Task.detached(priority: .utility) {
                await Self.makeEvidenceInputs(
                    candidates: batchCandidates,
                    documentsByID: documentsByID,
                    preparedQuery: preparedQuery,
                    maximumNewEmbeddingsPerDocument: maximumNewEmbeddingsPerDocument
                )
            }.value
            inputs.append(contentsOf: batchInputs.inputs)
            generatedEmbeddingCount += batchInputs.generatedEmbeddingCount
            aiSecondRerankState = .fetchingEvidence(
                completed: end,
                total: candidates.count
            )
            await Task.yield()
        }
        searchPerformanceLogger.info(
            "Passage retrieval finished candidates=\(candidates.count, privacy: .public) generated_embeddings=\(generatedEmbeddingCount, privacy: .public) per_document_limit=\(maximumNewEmbeddingsPerDocument, privacy: .public) seconds=\(Date().timeIntervalSince(retrievalStartedAt), privacy: .public)"
        )
        let scoreFingerprint = Self.globalScoringFingerprint(
            description: originalRequest,
            profile: plan.questionProfile,
            inputs: inputs,
            configuration: configuration
        )
        if let cached = historyRefreshFallbackRecord?.snapshot,
           applyCachedGlobalRanking(
               cached,
               candidates: candidates,
               fingerprint: scoreFingerprint
           ) {
            searchPerformanceLogger.info(
                "Global calibration reused fingerprint cache candidates=\(candidates.count, privacy: .public)"
            )
            return (elapsedSeconds(since: startedAt), true)
        }
        globalScoreFingerprint = scoreFingerprint
        var cardsByID = evidenceCards
        let missingRanges = Self.evidenceBatchRanges(
            totalCount: inputs.count,
            batchSize: aiEvidenceBatchSize
        ).filter { range in
            range.contains { cardsByID[inputs[$0].work.id] == nil }
        }
        let planner = aiQueryPlanner
        var analyzed = inputs.count - missingRanges.reduce(0) { partial, range in
            partial + range.filter { cardsByID[inputs[$0].work.id] == nil }.count
        }
        var freshlyAnalyzedIDs = Set<String>()
        aiSecondRerankState = .rankingEvidence(completed: analyzed, total: inputs.count)

        await withTaskGroup(of: (Range<Int>, [AIEvidenceCardOutput]?).self) { group in
            var next = 0
            func enqueue(_ range: Range<Int>) {
                let batch = Array(inputs[range])
                group.addTask {
                    do {
                        var outputs = try await planner.analyzeEvidenceBatch(
                            description: originalRequest,
                            profile: plan.questionProfile,
                            inputs: batch,
                            configuration: configuration
                        )
                        let returned = Set(outputs.map(\.index))
                        let missing = batch.indices.filter { !returned.contains($0) }
                        if !missing.isEmpty {
                            let retryInputs = missing.map { batch[$0] }
                            let retry = try await planner.analyzeEvidenceBatch(
                                description: originalRequest,
                                profile: plan.questionProfile,
                                inputs: retryInputs,
                                configuration: configuration
                            )
                            outputs += retry.compactMap { output in
                                guard missing.indices.contains(output.index) else { return nil }
                                return output.withIndex(missing[output.index])
                            }
                        }
                        return (range, outputs)
                    } catch {
                        return (range, nil)
                    }
                }
            }
            while next < min(evidenceAnalysisMaxConcurrent, missingRanges.count) {
                enqueue(missingRanges[next])
                next += 1
            }
            for await (range, outputs) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                let byIndex = outputs.map {
                    Dictionary(uniqueKeysWithValues: $0.map { ($0.index, $0) })
                } ?? [:]
                for absoluteIndex in range {
                    let input = inputs[absoluteIndex]
                    guard cardsByID[input.work.id] == nil else { continue }
                    let local = LocalEvidenceCardBuilder.make(
                        work: input.work,
                        profile: plan.questionProfile,
                        abstract: input.abstract,
                        passages: input.passages,
                        hasFullText: input.hasFullTextEvidence
                    )
                    let relativeIndex = absoluteIndex - range.lowerBound
                    if let output = byIndex[relativeIndex] {
                        cardsByID[input.work.id] = Self.evidenceCard(
                            output: output,
                            work: input.work,
                            local: local
                        )
                    } else {
                        cardsByID[input.work.id] = local
                    }
                    freshlyAnalyzedIDs.insert(input.work.id)
                    analyzed += 1
                }
                aiSecondRerankState = .rankingEvidence(
                    completed: min(analyzed, inputs.count),
                    total: inputs.count
                )
                if next < missingRanges.count {
                    enqueue(missingRanges[next])
                    next += 1
                }
            }
        }
        try ensureSearchIsActive(generation)

        let verificationIndices = inputs.indices.filter { index in
            let input = inputs[index]
            guard freshlyAnalyzedIDs.contains(input.work.id),
                  let model = cardsByID[input.work.id] else { return false }
            let local = LocalEvidenceCardBuilder.make(
                work: input.work,
                profile: plan.questionProfile,
                abstract: input.abstract,
                passages: input.passages,
                hasFullText: input.hasFullTextEvidence
            )
            return Self.needsCoreMismatchVerification(model: model, local: local)
        }
        if !verificationIndices.isEmpty {
            await withTaskGroup(of: (Int, AIEvidenceCardOutput?).self) { group in
                var next = 0
                func enqueue(_ index: Int) {
                    let input = inputs[index]
                    group.addTask {
                        do {
                            let output = try await planner.analyzeEvidenceBatch(
                                description: originalRequest,
                                profile: plan.questionProfile,
                                inputs: [input],
                                configuration: configuration
                            ).first
                            return (index, output)
                        } catch {
                            return (index, nil)
                        }
                    }
                }
                while next < min(evidenceAnalysisMaxConcurrent, verificationIndices.count) {
                    enqueue(verificationIndices[next])
                    next += 1
                }
                for await (index, output) in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    let input = inputs[index]
                    let local = LocalEvidenceCardBuilder.make(
                        work: input.work,
                        profile: plan.questionProfile,
                        abstract: input.abstract,
                        passages: input.passages,
                        hasFullText: input.hasFullTextEvidence
                    )
                    if let output {
                        let verified = Self.evidenceCard(
                            output: output,
                            work: input.work,
                            local: local
                        )
                        cardsByID[input.work.id] = Self.protectingStrongLocalCoreMatches(
                            in: verified,
                            supportedBy: local
                        )
                    } else if let initial = cardsByID[input.work.id] {
                        cardsByID[input.work.id] = Self.softeningUnverifiedCoreMismatches(
                            in: initial,
                            supportedBy: local
                        )
                    }
                    if next < verificationIndices.count {
                        enqueue(verificationIndices[next])
                        next += 1
                    }
                }
            }
            try ensureSearchIsActive(generation)
        }
        searchPerformanceLogger.info(
            "Evidence-card analysis finished candidates=\(candidates.count, privacy: .public) mismatch_verifications=\(verificationIndices.count, privacy: .public) seconds=\(Date().timeIntervalSince(retrievalStartedAt), privacy: .public)"
        )

        let cards = inputs.map { input in
            cardsByID[input.work.id] ?? LocalEvidenceCardBuilder.make(
                work: input.work,
                profile: plan.questionProfile,
                abstract: input.abstract,
                passages: input.passages,
                hasFullText: input.hasFullTextEvidence
            )
        }
        evidenceCards = Dictionary(uniqueKeysWithValues: cards.map { ($0.workID, $0) })
        let localScores = cards.map(EvidenceUsefulnessScorer.score)
        aiSecondRerankState = .calibrating(total: candidates.count)

        do {
            var outputs = try await planner.calibrateGlobalScores(
                description: originalRequest,
                profile: plan.questionProfile,
                cards: cards,
                works: candidates,
                configuration: configuration
            )
            let returned = Set(outputs.map(\.index))
            let missing = candidates.indices.filter { !returned.contains($0) }
            if !missing.isEmpty {
                let retry = try await planner.calibrateGlobalScores(
                    description: originalRequest,
                    profile: plan.questionProfile,
                    cards: missing.map { cards[$0] },
                    works: missing.map { candidates[$0] },
                    configuration: configuration
                )
                outputs += retry.compactMap { output in
                    guard missing.indices.contains(output.index) else { return nil }
                    return output.withIndex(missing[output.index])
                }
            }
            try ensureSearchIsActive(generation)
            let modelScores = try Self.validatedGlobalScores(
                outputs,
                candidateCount: candidates.count
            )
            let scoreByIndex = Self.safetyAdjustedGlobalScores(
                modelScores: modelScores,
                cards: cards
            )
            applyGlobalScores(
                candidates: candidates,
                cards: cards,
                scores: scoreByIndex,
                completed: true
            )
            searchPerformanceLogger.info(
                "Global calibration finished candidates=\(candidates.count, privacy: .public) seconds=\(Date().timeIntervalSince(startedAt), privacy: .public)"
            )
            return (elapsedSeconds(since: startedAt), true)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try ensureSearchIsActive(generation)
            globalScoreFingerprint = nil
            applyGlobalScores(
                candidates: candidates,
                cards: cards,
                scores: Dictionary(uniqueKeysWithValues: localScores.enumerated().map { ($0, $1) }),
                completed: false
            )
            aiSecondRerankState = .failed(
                "统一评分未完成，当前使用本地证据卡排序；重试会复用已获取的证据。"
            )
            return (elapsedSeconds(since: startedAt), false)
        }
    }

    nonisolated static func evidenceBatchRanges(
        totalCount: Int,
        batchSize: Int
    ) -> [Range<Int>] {
        guard totalCount > 0, batchSize > 0 else { return [] }
        return stride(from: 0, to: totalCount, by: batchSize).map { start in
            start..<min(start + batchSize, totalCount)
        }
    }

    nonisolated static func fullTextPreparationCandidates(
        _ candidates: [Work],
        limit: Int
    ) -> [Work] {
        Array(candidates.prefix(max(0, limit)))
    }

    nonisolated static func validatedGlobalScores(
        _ outputs: [AIGlobalScoreOutput],
        candidateCount: Int
    ) throws -> [Int: Int] {
        guard outputs.count == candidateCount,
              Set(outputs.map(\.index)).count == candidateCount,
              outputs.allSatisfy({ (0..<candidateCount).contains($0.index) }) else {
            throw AIPlannerError.invalidRanking
        }
        return Dictionary(uniqueKeysWithValues: outputs.map {
            ($0.index, min(100, max(0, $0.score)))
        })
    }

    nonisolated static func globallyRankedIndices(
        scores: [Int: Int],
        candidateCount: Int,
        minimumScore: Int
    ) -> [Int] {
        (0..<candidateCount)
            .compactMap { index -> (index: Int, score: Int)? in
                guard let score = scores[index], score >= minimumScore else { return nil }
                return (index, score)
            }
            .sorted {
                if $0.score == $1.score { return $0.index < $1.index }
                return $0.score > $1.score
            }
            .map(\.index)
    }

    nonisolated static func safetyAdjustedGlobalScores(
        modelScores: [Int: Int],
        cards: [StructuredEvidenceCard]
    ) -> [Int: Int] {
        return Dictionary(uniqueKeysWithValues: cards.indices.compactMap { index in
            guard let model = modelScores[index] else { return nil }
            let card = cards[index]
            let hasCoreMismatch = card.population == .mismatch
                || card.interventionOrExposure == .mismatch
                || card.outcome == .mismatch
            let isStrongDirectPrimary = card.role == .primary
                && [.match, .partial].contains(card.population)
                && [.match, .partial].contains(card.interventionOrExposure)
                && [.match, .partial].contains(card.outcome)
                && (card.reportsEffectEstimate
                    || (card.reportsSampleSize && card.hasComparatorGroup))
            let score: Int
            if hasCoreMismatch {
                score = min(4, model)
            } else if isStrongDirectPrimary {
                // Guard against an occasional global-calibration outlier that assigns a
                // low/background score to a well-supported primary results report.
                score = max(70, min(100, max(0, model)))
            } else {
                score = min(100, max(0, model))
            }
            return (index, score)
        })
    }

    nonisolated static func globalScoringFingerprint(
        description: String,
        profile: ResearchQuestionProfile?,
        inputs: [AIEvidenceRankingInput],
        configuration: AIProviderConfiguration
    ) -> String {
        var hasher = SHA256()
        func update(_ value: String) {
            let data = Data(value.utf8)
            hasher.update(data: Data("\(data.count):".utf8))
            hasher.update(data: data)
        }

        update("ragbio-global-scoring-v3-ai-primary-with-70-point-evidence-floor")
        update(description)
        update(configuration.provider.rawValue)
        update(configuration.model.trimmingCharacters(in: .whitespacesAndNewlines))
        update(configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let profileData = try? encoder.encode(profile ?? .empty)
        update(profileData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}")

        for input in inputs {
            update(input.work.id)
            update(input.work.title)
            update((input.work.publicationTypes ?? []).joined(separator: "\u{1f}"))
            update(AIQueryPlanner.abstractEvidence(input.abstract, maxCharacters: 2_800))
            let passages = input.passages.prefix(HybridRetriever.evidencePassageLimit)
            update(String(passages.count))
            for hit in passages {
                update(hit.paragraph.locator)
                update(AIQueryPlanner.passageEvidence(hit, maxCharacters: 1_000))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func canReuseGlobalRanking(
        from snapshot: SearchHistorySnapshot,
        candidates: [Work],
        fingerprint: String
    ) -> Bool {
        guard snapshot.globalScoreFingerprint == fingerprint,
              snapshot.completedAIStage == .globalEvidenceRanking,
              snapshot.candidateWorks.map(\.id) == candidates.map(\.id) else {
            return false
        }
        let candidateIDs = Set(candidates.map(\.id))
        let rankedIDs = snapshot.rankedWorks.map(\.id)
        return Set(rankedIDs).count == rankedIDs.count
            && rankedIDs.allSatisfy(candidateIDs.contains)
            && rankedIDs.allSatisfy { snapshot.aiScores[$0] != nil }
            && rankedIDs.allSatisfy { snapshot.aiEvidenceLevels[$0] != nil }
            && candidates.allSatisfy { snapshot.evidenceCards[$0.id] != nil }
    }

    private func applyCachedGlobalRanking(
        _ snapshot: SearchHistorySnapshot,
        candidates: [Work],
        fingerprint: String
    ) -> Bool {
        guard Self.canReuseGlobalRanking(
            from: snapshot,
            candidates: candidates,
            fingerprint: fingerprint
        ) else {
            return false
        }
        let currentByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let ranked = snapshot.rankedWorks.compactMap { currentByID[$0.id] }
        guard ranked.count == snapshot.rankedWorks.count else { return false }

        let rankedIDs = Set(ranked.map(\.id))
        aiRankedWorks = ranked
        aiScores = snapshot.aiScores.filter { rankedIDs.contains($0.key) }
        aiReasons = [:]
        aiEvidenceLevels = snapshot.aiEvidenceLevels.filter { rankedIDs.contains($0.key) }
        evidenceCards = snapshot.evidenceCards.filter { currentByID[$0.key] != nil }
        globalScoreFingerprint = fingerprint
        totalCount = ranked.count
        aiRerankState = .completed(candidates: candidates.count, retained: ranked.count)
        let fullText = ranked.filter {
            aiEvidenceLevels[$0.id]?.hasPrefix("全文") == true
        }.count
        aiSecondRerankState = .completed(
            fullText: fullText,
            abstractOnly: ranked.count - fullText,
            retained: ranked.count
        )
        return true
    }

    nonisolated static func needsCoreMismatchVerification(
        model: StructuredEvidenceCard,
        local: StructuredEvidenceCard
    ) -> Bool {
        guard EvidenceUsefulnessScorer.score(local) >= 50 else { return false }
        return (model.population == .mismatch && local.population != .unclear)
            || (model.interventionOrExposure == .mismatch
                && local.interventionOrExposure != .unclear)
            || (model.outcome == .mismatch && local.outcome != .unclear)
    }

    nonisolated static func evidenceCard(
        output: AIEvidenceCardOutput,
        work: Work,
        local: StructuredEvidenceCard
    ) -> StructuredEvidenceCard {
        StructuredEvidenceCard(
            workID: work.id,
            population: output.population,
            interventionOrExposure: output.interventionOrExposure,
            comparator: output.comparator,
            outcome: output.outcome,
            context: output.context,
            role: resolvedEvidenceRole(output.role, for: work),
            reportsEffectEstimate: output.reportsEffectEstimate,
            reportsSampleSize: output.reportsSampleSize,
            hasComparatorGroup: output.hasComparatorGroup,
            reportsFollowUp: output.reportsFollowUp,
            uniqueContribution: output.uniqueContribution,
            confidence: local.confidence,
            studyFamilyID: local.studyFamilyID,
            evidenceBasis: local.evidenceBasis
        )
    }

    nonisolated static func softeningUnverifiedCoreMismatches(
        in model: StructuredEvidenceCard,
        supportedBy local: StructuredEvidenceCard
    ) -> StructuredEvidenceCard {
        func softened(_ modelValue: EvidenceMatch, _ localValue: EvidenceMatch) -> EvidenceMatch {
            modelValue == .mismatch && localValue != .unclear ? .unclear : modelValue
        }
        return StructuredEvidenceCard(
            workID: model.workID,
            population: softened(model.population, local.population),
            interventionOrExposure: softened(
                model.interventionOrExposure,
                local.interventionOrExposure
            ),
            comparator: model.comparator,
            outcome: softened(model.outcome, local.outcome),
            context: model.context,
            role: model.role,
            reportsEffectEstimate: model.reportsEffectEstimate,
            reportsSampleSize: model.reportsSampleSize,
            hasComparatorGroup: model.hasComparatorGroup,
            reportsFollowUp: model.reportsFollowUp,
            uniqueContribution: model.uniqueContribution,
            confidence: model.confidence,
            studyFamilyID: model.studyFamilyID,
            evidenceBasis: model.evidenceBasis
        )
    }

    nonisolated static func protectingStrongLocalCoreMatches(
        in model: StructuredEvidenceCard,
        supportedBy local: StructuredEvidenceCard
    ) -> StructuredEvidenceCard {
        guard EvidenceUsefulnessScorer.score(local) >= 50 else { return model }
        func protected(_ modelValue: EvidenceMatch, _ localValue: EvidenceMatch) -> EvidenceMatch {
            modelValue == .mismatch && localValue != .unclear ? .unclear : modelValue
        }
        return StructuredEvidenceCard(
            workID: model.workID,
            population: protected(model.population, local.population),
            interventionOrExposure: protected(
                model.interventionOrExposure,
                local.interventionOrExposure
            ),
            comparator: model.comparator,
            outcome: model.outcome,
            context: model.context,
            role: model.role,
            reportsEffectEstimate: model.reportsEffectEstimate,
            reportsSampleSize: model.reportsSampleSize,
            hasComparatorGroup: model.hasComparatorGroup,
            reportsFollowUp: model.reportsFollowUp,
            uniqueContribution: model.uniqueContribution,
            confidence: model.confidence,
            studyFamilyID: model.studyFamilyID,
            evidenceBasis: model.evidenceBasis
        )
    }

    nonisolated static func resolvedEvidenceRole(
        _ proposed: EvidenceRole,
        for work: Work
    ) -> EvidenceRole {
        if work.id.lowercased().contains("clinicaltrials.gov") {
            return .registry
        }
        guard let kind = work.nonPrimaryPublicationKind else { return proposed }
        switch kind {
        case .review, .metaAnalysis, .guideline, .consensus,
             .retracted, .editorial, .comment, .letter:
            return .background
        case .studyProtocol:
            return .protocolRecord
        }
    }

    private func applyGlobalScores(
        candidates: [Work],
        cards: [StructuredEvidenceCard],
        scores: [Int: Int],
        completed: Bool
    ) {
        let ordered = Self.globallyRankedIndices(
            scores: scores,
            candidateCount: candidates.count,
            minimumScore: minimumGlobalRelevanceScore
        )
        aiRankedWorks = ordered.map { candidates[$0] }
        aiScores = Dictionary(uniqueKeysWithValues: ordered.map {
            (candidates[$0].id, scores[$0] ?? 0)
        })
        aiReasons = [:]
        aiEvidenceLevels = Dictionary(uniqueKeysWithValues: ordered.map { index in
            let card = cards[index]
            let label: String
            switch card.confidence {
            case .high: label = "全文证据"
            case .medium: label = "摘要证据"
            case .low: label = "仅元数据"
            }
            return (candidates[index].id, label)
        })
        totalCount = aiRankedWorks.count
        aiRerankState = .completed(candidates: candidates.count, retained: aiRankedWorks.count)
        if completed {
            let fullText = ordered.filter { cards[$0].confidence == .high }.count
            aiSecondRerankState = .completed(
                fullText: fullText,
                abstractOnly: ordered.count - fullText,
                retained: ordered.count
            )
        }
    }

    private func applyGlobalRankingFailure(candidates: [Work], message: String) {
        globalScoreFingerprint = nil
        aiRankedWorks = candidates
        totalCount = candidates.count
        aiScores = [:]
        aiReasons = [:]
        aiEvidenceLevels = Dictionary(uniqueKeysWithValues: candidates.map {
            ($0.id, "全局精排未完成")
        })
        aiRerankState = .localReady(candidates: candidates.count)
        aiSecondRerankState = .failed("全局精排未完成：\(message)")
    }

    private func planAISearchWithSoftTimeout(
        description: String,
        configuration: AIProviderConfiguration,
        currentSort: SearchSort,
        currentFromYear: Int?,
        currentOpenAccessOnly: Bool,
        timeoutSeconds: Int
    ) async throws -> AISearchPlan {
        let planner = aiQueryPlanner
        return try await withThrowingTaskGroup(of: AISearchPlan.self) { group in
            group.addTask {
                try await planner.plan(
                    description: description,
                    configuration: configuration,
                    currentSort: currentSort,
                    currentFromYear: currentFromYear,
                    currentOpenAccessOnly: currentOpenAccessOnly
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw AISearchPipelineError.searchPlanning(
                    "大模型未在 \(timeoutSeconds) 秒内返回检索式。请重试，或检查当前模型/API Key 是否可用。"
                )
            }
            guard let plan = try await group.next() else {
                throw AISearchPipelineError.searchPlanning("大模型没有返回检索式。")
            }
            group.cancelAll()
            return plan
        }
    }

    private func fetchAICandidates(
        plan: AISearchPlan,
        originalRequest: String,
        configuration: AIProviderConfiguration,
        apiKey: String?
    ) async throws -> (works: [Work], aiNotice: String?, pubMedNotice: String?) {
        let email = UserDefaults.standard
            .string(forKey: SettingsKeys.contactEmail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let openAlexQueries = Array(plan.effectiveOpenAlexQueries.prefix(4))
        let pubMedQueries = Array(plan.effectivePubMedQueries.prefix(4))
        let registryQueries = Array(plan.effectiveClinicalTrialsQueries.prefix(3))
        let laneResults = await withTaskGroup(
            of: (source: DiscoverySource, lane: Int, works: [Work], error: String?).self,
            returning: [(source: DiscoverySource, lane: Int, works: [Work], error: String?)].self
        ) { group in
            for (lane, query) in openAlexQueries.enumerated() {
                group.addTask {
                    do {
                        let response = try await self.client.search(
                            query: query,
                            sort: .relevance,
                            fromYear: nil,
                            openAccessOnly: false,
                            apiKey: apiKey,
                            page: 1,
                            perPage: self.openAlexCandidatePageSize,
                            timeout: 15,
                            maxAttempts: 3
                        )
                        return (.openAlex, lane, response.results, nil)
                    } catch {
                        return (.openAlex, lane, [], error.localizedDescription)
                    }
                }
            }
            for (lane, query) in pubMedQueries.enumerated() {
                group.addTask {
                    do {
                        let works = try await self.pubMedClient.search(
                            query: query,
                            fromYear: nil,
                            maxResults: self.pubMedCandidatePageSize,
                            contactEmail: (email?.isEmpty == false) ? email : nil,
                            timeout: 25
                        )
                        return (.pubMed, lane, works, nil)
                    } catch {
                        return (.pubMed, lane, [], error.localizedDescription)
                    }
                }
            }
            for (lane, query) in registryQueries.enumerated() {
                group.addTask {
                    do {
                        let works = try await self.clinicalTrialsClient.search(
                            query: query,
                            pageSize: 50,
                            timeout: 18
                        )
                        return (.clinicalTrials, lane, works, nil)
                    } catch {
                        return (.clinicalTrials, lane, [], error.localizedDescription)
                    }
                }
            }
            var values: [(source: DiscoverySource, lane: Int, works: [Work], error: String?)] = []
            for await value in group { values.append(value) }
            return values
        }

        let sourceOrder: [DiscoverySource: Int] = [.pubMed: 0, .openAlex: 1, .clinicalTrials: 2]
        let orderedLanes = laneResults.sorted {
            let left = sourceOrder[$0.source] ?? 9
            let right = sourceOrder[$1.source] ?? 9
            return left == right ? $0.lane < $1.lane : left < right
        }
        let hits = orderedLanes.flatMap { result in
            result.works.enumerated().map { offset, work in
                SearchCandidateHit(
                    work: work,
                    source: result.source,
                    lane: result.lane,
                    rank: offset + 1
                )
            }
        }
        var fused = CandidateFusion.fuse(hits)
        guard !fused.isEmpty else {
            let errors = laneResults.compactMap(\.error)
            throw AISearchPipelineError.candidateFetch(
                errors.isEmpty
                    ? "OpenAlex、PubMed 和 ClinicalTrials.gov 都没有返回候选研究"
                    : errors.joined(separator: "；")
            )
        }
        let citationSeeds = fused.filter {
            guard let kind = $0.work.nonPrimaryPublicationKind else { return false }
            return kind == .review || kind == .metaAnalysis
        }.prefix(2).map(\.work)
        if !citationSeeds.isEmpty {
            let citationWorks = await client.citationNeighbors(
                for: citationSeeds,
                relevanceQuery: plan.searchQuery,
                apiKey: apiKey,
                referencesPerSeed: 200,
                citationsPerSeed: 40
            )
            if !citationWorks.isEmpty {
                let citationHits = citationWorks.enumerated().map { offset, work in
                    SearchCandidateHit(
                        work: work,
                        source: .citation,
                        lane: 0,
                        rank: offset + 1
                    )
                }
                fused = CandidateFusion.fuse(hits + citationHits)
            }
        }
        let preTriage = CandidatePoolSelector.select(
            from: fused,
            decisions: [:],
            profile: plan.questionProfile,
            limit: min(triagePoolLimit, fused.count),
            unclearReserve: min(triagePoolLimit, fused.count),
            backgroundReserve: min(20, triagePoolLimit)
        )
        let preTriageIDs = Set(preTriage.map(\.id))
        let triageFused = fused.filter { preTriageIDs.contains($0.work.id) }
        let decisions = await triageCandidatePool(
            triageFused.map(\.work),
            originalRequest: originalRequest,
            profile: plan.questionProfile,
            configuration: configuration
        )
        let candidates = CandidatePoolSelector.select(
            from: triageFused,
            decisions: decisions,
            profile: plan.questionProfile,
            limit: aiCandidateLimit
        )

        let failed = laneResults.filter { $0.error != nil }.count
        let notice = failed > 0 ? "部分检索通道暂时不可用，已用成功来源继续。" : nil
        return (candidates, notice, nil)
    }

    private func triageCandidatePool(
        _ works: [Work],
        originalRequest: String,
        profile: ResearchQuestionProfile?,
        configuration: AIProviderConfiguration
    ) async -> [Int: AICandidateTriageOutput] {
        guard !works.isEmpty else { return [:] }
        let ranges = Self.evidenceBatchRanges(
            totalCount: works.count,
            batchSize: candidateTriageBatchSize
        )
        let planner = aiQueryPlanner
        var decisions: [Int: AICandidateTriageOutput] = [:]
        await withTaskGroup(of: (Range<Int>, [AICandidateTriageOutput]?).self) { group in
            var next = 0
            func enqueue(_ range: Range<Int>) {
                let batch = Array(works[range])
                group.addTask {
                    do {
                        let output = try await planner.triageCandidateBatch(
                            description: originalRequest,
                            profile: profile,
                            works: batch,
                            configuration: configuration
                        )
                        return (range, output)
                    } catch {
                        return (range, nil)
                    }
                }
            }
            while next < min(candidateTriageMaxConcurrent, ranges.count) {
                enqueue(ranges[next])
                next += 1
            }
            for await (range, outputs) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
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

    /// Best-effort PubMed discovery. Failures return an empty list so OpenAlex results
    /// are never blocked by a PubMed error or timeout.
    var activeAIProvider: AIProvider {
        let raw = UserDefaults.standard.string(forKey: SettingsKeys.activeAIProvider)
        return raw.flatMap(AIProvider.init(rawValue:)) ?? .deepSeek
    }

    func ensureFullTextReviewSummary(for work: Work) async {
        guard let document = availableFullTextDocument(for: work) else { return }
        let context = captureHistoryMutationContext()
        let configuration = AIProviderConfiguration.load(activeAIProvider)
        await generateFullTextReviewSummaries(
            [AIFullTextSummaryInput(work: work, document: document)],
            configuration: configuration,
            context: context
        )
    }

    /// Lazily generates the per-paper Article Summary (systematic-review extraction note) the
    /// first time the user opens a paper that has readable full text. Best-effort.
    func ensureArticleSummary(for work: Work) async {
        guard articleSummaries[work.id] == nil,
              !articleSummaryInProgress.contains(work.id),
              let document = availableFullTextDocument(for: work),
              document.source.isFullText else { return }
        let context = captureHistoryMutationContext()
        let configuration = AIProviderConfiguration.load(activeAIProvider)
        guard configuration.isConfigured else {
            articleSummaryErrors[work.id] = "No AI provider is configured."
            return
        }
        articleSummaryInProgress.insert(work.id)
        articleSummaryErrors.removeValue(forKey: work.id)
        defer {
            if isCurrentHistoryMutationContext(context) {
                articleSummaryInProgress.remove(work.id)
            }
        }
        do {
            let note = try await aiQueryPlanner.articleExtractionNote(
                work: work,
                document: document,
                configuration: configuration
            )
            guard isCurrentHistoryMutationContext(context) else { return }
            articleSummaries[work.id] = note
            scheduleCompletedStageSave()
        } catch {
            guard isCurrentHistoryMutationContext(context) else { return }
            articleSummaryErrors[work.id] = error.localizedDescription
        }
    }

    private func startFullTextReviewSummaryGeneration(
        for pairs: [(work: Work, document: FullTextDocument)],
        configuration: AIProviderConfiguration
    ) {
        let inputs = pairs
            .filter { fullTextReviewSummaries[$0.work.id] == nil }
            .filter { !fullTextReviewSummaryInProgress.contains($0.work.id) }
            .map { AIFullTextSummaryInput(work: $0.work, document: $0.document) }
        guard !inputs.isEmpty else { return }
        let context = captureHistoryMutationContext()
        Task {
            guard isCurrentHistoryMutationContext(context) else { return }
            await generateFullTextReviewSummaries(
                inputs,
                configuration: configuration,
                context: context
            )
        }
    }

    private func generateFullTextReviewSummaries(
        _ inputs: [AIFullTextSummaryInput],
        configuration: AIProviderConfiguration,
        context: HistoryMutationContext
    ) async {
        guard isCurrentHistoryMutationContext(context) else { return }
        let pending = inputs
            .filter { $0.document.source.isFullText }
            .filter { fullTextReviewSummaries[$0.work.id] == nil }
            .filter { !fullTextReviewSummaryInProgress.contains($0.work.id) }
        guard !pending.isEmpty else { return }

        for input in pending {
            fullTextReviewSummaryInProgress.insert(input.work.id)
            fullTextReviewSummaryErrors.removeValue(forKey: input.work.id)
        }

        func fallback(_ input: AIFullTextSummaryInput) -> LiteratureReviewSummary {
            LiteratureReviewSummaryBuilder.make(work: input.work, document: input.document)
        }

        defer {
            if isCurrentHistoryMutationContext(context) {
                for input in pending {
                    fullTextReviewSummaryInProgress.remove(input.work.id)
                }
            }
        }

        guard configuration.isConfigured else {
            for input in pending {
                fullTextReviewSummaries[input.work.id] = fallback(input)
                fullTextReviewSummaryErrors[input.work.id] = "No AI provider is configured; showing a local full-text draft."
            }
            scheduleCompletedStageSave()
            return
        }

        do {
            let outputs = try await aiQueryPlanner.summarizeFullTextBatch(
                pending,
                configuration: configuration
            )
            guard isCurrentHistoryMutationContext(context) else { return }
            let outputsByIndex = Dictionary(uniqueKeysWithValues: outputs.map { ($0.index, $0) })
            for index in pending.indices {
                let input = pending[index]
                let fallbackSummary = fallback(input)
                if let output = outputsByIndex[index] {
                    fullTextReviewSummaries[input.work.id] = normalizedSummary(
                        output.summary,
                        fallback: fallbackSummary
                    )
                } else {
                    fullTextReviewSummaries[input.work.id] = fallbackSummary
                    fullTextReviewSummaryErrors[input.work.id] = "The AI provider did not return this paper summary; showing a local full-text draft."
                }
            }
        } catch {
            guard isCurrentHistoryMutationContext(context) else { return }
            for input in pending {
                fullTextReviewSummaries[input.work.id] = fallback(input)
                fullTextReviewSummaryErrors[input.work.id] = "AI summary failed; showing a local full-text draft: \(error.localizedDescription)"
            }
        }
        guard isCurrentHistoryMutationContext(context) else { return }
        scheduleCompletedStageSave()
    }

    private func normalizedSummary(
        _ summary: LiteratureReviewSummary,
        fallback: LiteratureReviewSummary
    ) -> LiteratureReviewSummary {
        func value(_ candidate: String, _ fallback: String) -> String {
            let clean = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? fallback : clean
        }
        let fallbackMetrics = fallback.metrics
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let candidateMetrics = summary.metrics
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isBareMetric($0) }
        return LiteratureReviewSummary(
            topic: value(summary.topic, fallback.topic),
            methods: value(summary.methods, fallback.methods),
            results: value(summary.results, fallback.results),
            outlook: value(summary.outlook, fallback.outlook),
            metrics: candidateMetrics.isEmpty ? fallbackMetrics : candidateMetrics
        )
    }

    private func isBareMetric(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"\d"#, options: .regularExpression) != nil else {
            return false
        }
        if trimmed.contains(":") || trimmed.contains("=") {
            return false
        }
        let words = trimmed
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.count <= 5
    }

    private nonisolated static func focusQuery(from text: String) -> String {
        let clean = cleanSummarySourceText(text)
        guard clean.count > 180 else { return clean }
        let prefix = clean.prefix(180)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace])
        }
        return String(prefix)
    }

    private nonisolated static func cleanSummarySourceText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func goToPage(_ page: Int) async {
        guard !lastQuery.isEmpty, (1...totalPages).contains(page), page != currentPage else {
            return
        }
        guard !aiRankedWorks.isEmpty else { return }
        showAIPage(page)
    }

    func retryGlobalEvidenceRanking() async {
        guard !aiCandidateWorks.isEmpty, !lastQuery.isEmpty, let plan = lastAIPlan else { return }
        let generation = searchGeneration
        let candidates = aiCandidateWorks
        let originalRequest = currentHistoryRecord?.displayQuery ?? query
        let configuration = AIProviderConfiguration.load(activeAIProvider)
        guard configuration.isConfigured else {
            aiSecondRerankState = .failed(
                AIPlannerError.notConfigured(configuration.provider).localizedDescription
            )
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await rankAllCandidatesWithEvidence(
                candidates,
                originalRequest: originalRequest,
                retrievalQuery: lastQuery,
                plan: plan,
                configuration: configuration,
                generation: generation
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == searchGeneration else { return }
            applyGlobalRankingFailure(candidates: candidates, message: error.localizedDescription)
        }
        guard generation == searchGeneration else { return }
        showAIPage(1)
        scheduleCompletedStageSave()
    }

    nonisolated static func loadFullTextWithSoftTimeout(
        service: FullTextService,
        work: Work,
        apiKey: String?,
        contactEmail: String?,
        semanticScholarAPIKey: String?,
        seconds: Int
    ) async -> FullTextDocument? {
        await withTaskGroup(of: FullTextDocument?.self) { group in
            group.addTask(priority: .utility) {
                try? await service.load(
                    work: work,
                    apiKey: apiKey,
                    contactEmail: contactEmail,
                    semanticScholarAPIKey: semanticScholarAPIKey
                )
            }
            group.addTask(priority: .utility) {
                do {
                    try await Task.sleep(for: .seconds(seconds))
                    return nil
                } catch {
                    return nil
                }
            }
            let document = await group.next() ?? nil
            group.cancelAll()
            guard let document else { return nil }
            guard fullTextDocument(document, matches: work) else {
                if document.source.isFullText {
                    await service.clearCache(work: work)
                }
                return nil
            }
            return document
        }
    }

    private nonisolated static func makeEvidenceInputs(
        candidates: [Work],
        documentsByID: [String: FullTextDocument],
        preparedQuery: HybridRetrievalQuery,
        maximumNewEmbeddingsPerDocument: Int
    ) async -> (inputs: [AIEvidenceRankingInput], generatedEmbeddingCount: Int) {
        var inputs: [AIEvidenceRankingInput] = []
        var generatedEmbeddingCount = 0
        for work in candidates {
            let document = documentsByID[work.id]
            let passages: [PassageHit]
            if let document, document.source.isFullText {
                let result = await HybridRetriever.searchCached(
                    preparedQuery: preparedQuery,
                    workID: work.id,
                    paragraphs: document.paragraphs,
                    limit: HybridRetriever.evidencePassageLimit,
                    maximumNewEmbeddings: maximumNewEmbeddingsPerDocument
                )
                passages = result.hits
                generatedEmbeddingCount += result.generatedEmbeddingCount
            } else {
                passages = []
            }
            inputs.append(AIEvidenceRankingInput(
                work: work,
                abstract: work.abstractText,
                passages: passages,
                source: document?.source
            ))
        }
        return (inputs, generatedEmbeddingCount)
    }

    nonisolated static func newEmbeddingAllowance(fullTextDocumentCount: Int) -> Int {
        guard fullTextDocumentCount > 0 else { return 0 }
        let fairShare = maximumNewEmbeddingsPerSearch / fullTextDocumentCount
        return min(
            HybridRetriever.maximumNewEmbeddingsPerDocument,
            max(1, fairShare)
        )
    }

    private func showAIPage(
        _ page: Int,
        persistStage: Bool = true
    ) {
        guard page >= 1 else { return }
        let rankedWorks = aiRankedWorks.filter(matchesActiveResultFilters)
        totalCount = rankedWorks.count
        let start = (page - 1) * pageSize
        guard start < rankedWorks.count || (page == 1 && rankedWorks.isEmpty) else {
            return
        }
        let end = min(start + pageSize, rankedWorks.count)
        works = start < end ? Array(rankedWorks[start..<end]) : []
        currentPage = page
        evidence = EvidenceExtractor.extract(query: lastQuery, works: works)
        selection = works.first?.id
        fullTextState = .idle
        fullTextDocument = nil
        passageHits = []
        passageQuery = lastQuery
        if persistStage {
            scheduleCompletedStageSave()
        }
    }

    private func applyActiveResultFilters() {
        guard !lastQuery.isEmpty, !isLoading else { return }
        showAIPage(1)
    }

    private func matchesActiveResultFilters(_ work: Work) -> Bool {
        Self.matchesResultFilters(
            work,
            fromYear: fromYearEnabled ? fromYear : nil,
            openAccessOnly: openAccessOnly
        )
    }

    nonisolated static func matchesResultFilters(
        _ work: Work,
        fromYear: Int?,
        openAccessOnly: Bool
    ) -> Bool {
        if openAccessOnly, !work.isOpenAccess {
            return false
        }
        if let fromYear {
            guard let publicationYear = work.publicationYear,
                  publicationYear >= fromYear else {
                return false
            }
        }
        return true
    }

    nonisolated static func enforcingSearchControls(
        on plan: AISearchPlan,
        fromYear: Int?,
        openAccessOnly: Bool
    ) -> AISearchPlan {
        AISearchPlan(
            searchQuery: plan.searchQuery,
            fromYear: fromYear ?? plan.fromYear,
            openAccessOnly: openAccessOnly || plan.openAccessOnly,
            sort: plan.sort,
            explanation: plan.explanation,
            pubMedQuery: plan.pubMedQuery,
            questionProfile: plan.questionProfile,
            openAlexQueries: plan.openAlexQueries,
            pubMedQueries: plan.pubMedQueries,
            clinicalTrialsQueries: plan.clinicalTrialsQueries
        )
    }

    private func ensureSearchIsActive(_ generation: Int) throws {
        try Task.checkCancellation()
        guard generation == searchGeneration else {
            throw CancellationError()
        }
    }

    private func elapsedSeconds(since date: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(date))
    }

    private nonisolated static func fullTextDocument(
        _ document: FullTextDocument,
        matches work: Work
    ) -> Bool {
        if document.source == .importedPDF {
            return true
        }

        let titleTerms = significantTitleTerms(work.title)
        guard titleTerms.count >= 2 else { return true }

        let haystack = normalizedSearchText(
            ([document.title] + document.paragraphs.prefix(20).map(\.text))
                .joined(separator: " ")
        )
        let exactTitle = normalizedSearchText(work.title)
        if exactTitle.count >= 20, haystack.contains(exactTitle) {
            return true
        }

        let matched = titleTerms.filter { haystack.contains($0) }.count
        let required = min(4, max(2, Int(ceil(Double(titleTerms.count) * 0.35))))
        return matched >= required
    }

    private nonisolated static func significantTitleTerms(_ title: String) -> [String] {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "from", "into", "onto", "about", "between",
            "among", "using", "based", "study", "studies", "review", "analysis",
            "systematic", "meta", "men", "women", "girls", "boys", "adult", "adults",
            "child", "children", "adolescent", "adolescents", "patient", "patients",
            "in", "on", "of", "to", "a", "an", "is", "are"
        ]
        return normalizedSearchText(title)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !stopwords.contains($0) }
            .uniqued()
    }

    private nonisolated static func evidenceRetrievalQuery(
        originalRequest: String,
        retrievalQuery: String
    ) -> String {
        let stopwords: Set<String> = [
            "the", "and", "or", "not", "for", "with", "from", "into", "onto", "about",
            "between", "among", "using", "based", "study", "studies", "review",
            "analysis", "association", "relationship", "effect", "effects", "impact",
            "in", "on", "of", "to", "a", "an", "is", "are"
        ]
        var tokens = normalizedSearchText("\(originalRequest) \(retrievalQuery)")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopwords.contains($0) }

        if tokens.contains("gi") {
            tokens.append("gastrointestinal")
        }
        if tokens.contains("ndc") {
            tokens.append(contentsOf: ["national", "drug", "code", "codes"])
        }

        return tokens.uniqued().joined(separator: " ")
    }

    private nonisolated static func normalizedSearchText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9]+",
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func select(workID: Work.ID?) {
        guard selection != workID else { return }
        selection = workID
        fullTextState = .idle
        fullTextDocument = nil
        passageHits = []
        passageQuery = lastQuery
        scheduleCompletedStageSave()
    }

    func loadFullText(for work: Work, forceRefresh: Bool = false) async {
        let context = captureHistoryMutationContext()
        fullTextState = .loading
        if forceRefresh {
            await fullTextService.clearCache(work: work)
            guard isCurrentHistoryMutationContext(context) else { return }
        }
        do {
            let apiKey = CredentialStore.string(for: .openAlexAPIKey)
            let semanticScholarAPIKey = CredentialStore.string(for: .semanticScholarAPIKey)
            let contactEmail = UserDefaults.standard.string(forKey: SettingsKeys.contactEmail)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let document = try await fullTextService.load(
                work: work,
                apiKey: apiKey,
                contactEmail: contactEmail,
                semanticScholarAPIKey: semanticScholarAPIKey
            )
            guard isCurrentHistoryMutationContext(context) else { return }
            guard Self.fullTextDocument(document, matches: work) else {
                if document.source.isFullText {
                    await fullTextService.clearCache(work: work)
                }
                throw NSError(
                    domain: "RagBio.FullText",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "读取到的开放全文与当前论文标题不匹配，已忽略该来源。请尝试导入你确认正确的 PDF。"
                    ]
                )
            }
            guard selection == work.id else {
                fullTextState = .idle
                return
            }
            fullTextDocument = document
            if document.source.isFullText {
                aiFullTextDocuments[work.id] = document
                startFullTextReviewSummaryGeneration(
                    for: [(work, document)],
                    configuration: AIProviderConfiguration.load(activeAIProvider)
                )
            }
            fullTextState = .loaded
            searchPassages()
            scheduleCompletedStageSave()
        } catch is CancellationError {
            guard isCurrentHistoryMutationContext(context) else { return }
            if selection == work.id {
                fullTextState = .idle
            }
            return
        } catch {
            guard isCurrentHistoryMutationContext(context) else { return }
            fullTextState = .failed(error.localizedDescription)
        }
    }

    /// User-initiated full-text lookup for the Summary tab. Unlike the exhaustive manual
    /// loader, this has a firm total budget so the UI can never remain in a loading state.
    func loadFullTextForSummary(for work: Work, timeoutSeconds: Int = 15) async {
        let context = captureHistoryMutationContext()
        fullTextState = .loading
        let apiKey = CredentialStore.string(for: .openAlexAPIKey)
        let semanticScholarAPIKey = CredentialStore.string(for: .semanticScholarAPIKey)
        let contactEmail = UserDefaults.standard.string(forKey: SettingsKeys.contactEmail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let document = await Self.loadFullTextWithSoftTimeout(
            service: fullTextService,
            work: work,
            apiKey: apiKey,
            contactEmail: contactEmail,
            semanticScholarAPIKey: semanticScholarAPIKey,
            seconds: timeoutSeconds
        )

        guard isCurrentHistoryMutationContext(context) else { return }
        guard !Task.isCancelled else {
            if selection == work.id { fullTextState = .idle }
            return
        }
        guard selection == work.id else {
            fullTextState = .idle
            return
        }
        guard let document, document.source.isFullText else {
            fullTextState = .failed(
                "No accessible full text was found within \(timeoutSeconds) seconds, so an AI summary could not be generated."
            )
            return
        }

        fullTextDocument = document
        aiFullTextDocuments[work.id] = document
        fullTextState = .loaded
        searchPassages()
        scheduleCompletedStageSave()
    }

    func importPDF(for work: Work) async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择你有权访问的论文 PDF。文件只在本机解析。"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let context = captureHistoryMutationContext()
        fullTextState = .loading
        do {
            let document = try await fullTextService.importPDF(url: url, work: work)
            guard isCurrentHistoryMutationContext(context) else { return }
            guard selection == work.id else { return }
            fullTextDocument = document
            aiFullTextDocuments[work.id] = document
            startFullTextReviewSummaryGeneration(
                for: [(work, document)],
                configuration: AIProviderConfiguration.load(activeAIProvider)
            )
            fullTextState = .loaded
            searchPassages()
            scheduleCompletedStageSave()
        } catch {
            guard isCurrentHistoryMutationContext(context) else { return }
            fullTextState = .failed(error.localizedDescription)
        }
    }

    func searchPassages() {
        guard let document = fullTextDocument else {
            passageHits = []
            return
        }
        let cleanQuery = passageQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        passageHits = HybridRetriever.search(
            query: cleanQuery.isEmpty ? lastQuery : cleanQuery,
            paragraphs: document.paragraphs
        )
    }

    func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyEvidenceReport() {
        guard let report = evidenceReportText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func exportEvidenceReport() {
        guard let report = evidenceReportText() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "RagBio-\(safeFilename(lastQuery)).md"
        panel.message = "导出带精确来源的 Markdown 证据报告"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }

    private func evidenceReportText() -> String? {
        let activeQuery = passageQuery.isEmpty ? lastQuery : passageQuery
        if let document = fullTextDocument, !passageHits.isEmpty {
            let body = passageHits.prefix(10).enumerated().map { index, hit in
                "## [\(index + 1)] \(document.title)\n\n"
                    + "> \(hit.paragraph.text)\n\n"
                    + "- 定位：\(hit.paragraph.locator)\n"
                    + "- 来源：\(document.source.title)\n"
                    + "- 链接：\(document.sourceURL ?? selectedWork?.landingPageURL?.absoluteString ?? "")"
            }.joined(separator: "\n\n")
            return "# RagBio 证据报告\n\n**检索主题：** \(activeQuery)\n\n"
                + "**方法：** 本机全文混合检索；以下均为原文，不包含模型补写。\n\n"
                + body
        }
        guard !evidence.isEmpty else { return nil }
        let body = evidence.map {
            "## [\($0.citationNumber)] \($0.work.title)\n\n"
                + "> \($0.sentence)\n\n"
                + "- 年份：\($0.work.publicationYear.map(String.init) ?? "未知")\n"
                + "- 链接：\($0.work.landingPageURL?.absoluteString ?? $0.work.id)"
        }.joined(separator: "\n\n")
        return "# RagBio 证据报告\n\n**检索主题：** \(activeQuery)\n\n"
            + "**方法：** 仅从 OpenAlex 摘要抽取原句；未读取全文，不包含模型补写。\n\n"
            + body
    }

    private func evidenceTableSourceWorks() -> [Work] {
        if hasMarkedUseWorks { return useWorks }
        let ranked = aiRankedWorks.isEmpty ? works : aiRankedWorks
        var seen = Set<String>()
        return ranked.filter { seen.insert($0.id).inserted }
    }

    private func evidenceAccessStatuses() -> [String: EvidenceAccessStatus] {
        Dictionary(
            uniqueKeysWithValues: evidenceTableSourceWorks().map { work in
                (work.id, evidenceAccessStatus(for: work))
            }
        )
    }

    private func evidenceAccessStatus(for work: Work) -> EvidenceAccessStatus {
        if let document = availableFullTextDocument(for: work) {
            return document.source == .importedPDF ? .userPDFImported : .fullTextRead
        }
        if aiVisiblePageFullTextFailures[work.id] != nil {
            return .fullTextFailed
        }
        if work.abstractText != nil {
            return .abstractOnly
        }
        return .metadataOnly
    }

    private func evidenceSourceRefs() -> [String: [EvidenceSourceRef]] {
        var values: [String: [EvidenceSourceRef]] = [:]
        for work in evidenceTableSourceWorks() {
            guard let summary = fullTextReviewSummaries[work.id] else { continue }
            let refs = literatureReviewSourceExcerpts(for: work, summary: summary).map {
                EvidenceSourceRef(
                    field: $0.label,
                    section: sourceSection(from: $0.locator),
                    page: sourcePage(from: $0.locator),
                    ordinal: sourceOrdinal(from: $0.locator),
                    quotePreview: String($0.text.prefix(320))
                )
            }
            if !refs.isEmpty {
                values[work.id] = refs
            }
        }
        return values
    }

    private func sourceSection(from locator: String) -> String? {
        locator.components(separatedBy: "·")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sourceOrdinal(from locator: String) -> Int? {
        let pattern = #"(?:第\s*(\d+)\s*段|paragraph\s*(\d+))"#
        guard let range = locator.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        let match = String(locator[range])
        return Int(match.replacingOccurrences(of: #"\D"#, with: "", options: .regularExpression))
    }

    private func sourcePage(from locator: String) -> Int? {
        let pattern = #"(?:第\s*(\d+)\s*页|page\s*(\d+))"#
        guard let range = locator.range(
            of: pattern,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            return nil
        }
        let match = String(locator[range])
        return Int(match.replacingOccurrences(of: #"\D"#, with: "", options: .regularExpression))
    }

    private func fieldScanMarkdown(_ report: FieldScanReport) -> String {
        var lines: [String] = [
            "# Field Scan Report",
            "",
            "Query: \(report.query)",
            "Generated: \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))",
            "",
            "## Field Overview",
            "",
            report.fieldOverview,
            ""
        ]

        func appendClaims(_ title: String, _ claims: [SupportedClaim]) {
            lines.append("## \(title)")
            lines.append("")
            if claims.isEmpty {
                lines.append("_No supported claims returned._")
                lines.append("")
                return
            }
            for claim in claims {
                lines.append("- \(claim.text) [\(claim.evidenceLevel.title)]")
                lines.append("  - Supported by: \(claim.supportingWorkIDs.joined(separator: ", "))")
                if let caution = claim.caution, !caution.isEmpty {
                    lines.append("  - Caution: \(caution)")
                }
            }
            lines.append("")
        }

        lines.append("## Main Themes")
        lines.append("")
        for theme in report.mainThemes {
            lines.append("- **\(theme.name)** [\(theme.evidenceLevel.title)]: \(theme.summary)")
            lines.append("  - Supported by: \(theme.supportingWorkIDs.joined(separator: ", "))")
        }
        lines.append("")

        appendClaims("Key Findings", report.keyFindings)
        appendClaims("Conflicting Evidence", report.conflictingEvidence)
        appendClaims("Common Methods", report.commonMethods)
        appendClaims("Research Gaps", report.researchGaps)
        appendClaims("Future Directions", report.futureDirections)

        lines.append("## Must-read Papers")
        lines.append("")
        for paper in report.mustReadPapers {
            lines.append("- **\(paper.title)** (\(paper.category.title)): \(paper.reason)")
        }
        lines.append("")

        lines.append("## Limitations")
        lines.append("")
        for limitation in report.limitations {
            lines.append("- \(limitation)")
        }
        return lines.joined(separator: "\n")
    }

    private func exportText(
        _ text: String,
        suggestedName: String,
        message: String
    ) {
        let panel = NSSavePanel()
        let fileExtension: String
        if suggestedName.hasSuffix(".csv") {
            fileExtension = "csv"
        } else if suggestedName.hasSuffix(".txt") {
            fileExtension = "txt"
        } else {
            fileExtension = "md"
        }
        panel.allowedContentTypes = [UTType(filenameExtension: fileExtension) ?? .plainText]
        panel.nameFieldStringValue = suggestedName
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func safeFilename(_ value: String) -> String {
        let clean = value.replacingOccurrences(
            of: "[^A-Za-z0-9\\u4e00-\\u9fff_-]+",
            with: "-",
            options: .regularExpression
        )
        return String(clean.prefix(50))
    }
}

enum SettingsKeys {
    static let openAlexAPIKey = "openAlexAPIKey"
    static let semanticScholarAPIKey = "semanticScholarAPIKey"
    static let contactEmail = "contactEmail"
    static let grobidEndpoint = "grobidEndpoint"
    static let activeAIProvider = "activeAIProvider"

    static func aiModel(_ provider: AIProvider) -> String {
        "ai.\(provider.rawValue).model"
    }

    static func aiBaseURL(_ provider: AIProvider) -> String {
        "ai.\(provider.rawValue).baseURL"
    }
}
