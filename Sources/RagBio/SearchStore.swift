import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

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
    @Published private(set) var corpusState: CorpusAnalysisState = .idle
    @Published private(set) var corpusDocuments: [String: FullTextDocument] = [:]
    @Published private(set) var corpusHits: [CorpusPassageHit] = []
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
    private let fullTextService: FullTextService
    private let aiQueryPlanner: AIQueryPlanner
    private let historyStore: SearchHistoryStore
    private var aiRankedWorks: [Work] = []
    private var aiEnhancementTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var corpusAnalysisGeneration = 0
    private var historyRevision = 0
    private var historyMutationToken = SearchHistoryMutationToken()
    private var historyRefreshFallbackRecord: SearchHistoryRecord?
    private var useMutationRevision = 0
    private var useMutationTask: Task<Void, Never>?
    private var isRestoringHistory = false
    let pageSize = 20
    private let aiCandidateLimit = 50
    private let aiCandidatePageSize = 50
    private let aiCoarseRankingBatchSize = 25
    private let aiCoarseRankingLimit = 25
    private let aiEvidenceCandidateLimit = 20
    private typealias EvidenceRankResult = (
        work: Work,
        score: Int,
        relevant: Bool,
        reason: String,
        hasFullText: Bool,
        order: Int
    )

    struct HistoryMutationContext: Equatable {
        let searchGeneration: Int
        let corpusGeneration: Int
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
            totalCount: totalCount,
            currentPage: currentPage,
            selectedWorkID: selection,
            lastAIPlan: lastAIPlan,
            aiReasons: aiReasons,
            aiScores: aiScores,
            aiEvidenceLevels: aiEvidenceLevels,
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
        totalCount = snapshot.totalCount
        currentPage = snapshot.currentPage
        selection = snapshot.selectedWorkID
        lastQuery = snapshot.retrievalQuery
        lastAIPlan = snapshot.lastAIPlan
        aiReasons = snapshot.aiReasons
        aiScores = snapshot.aiScores
        aiEvidenceLevels = snapshot.aiEvidenceLevels
        aiSearchNotice = snapshot.aiSearchNotice
        pubMedNotice = snapshot.pubMedNotice
        searchTimingSummary = snapshot.searchTimingSummary
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
        corpusState = .idle
        corpusDocuments = [:]
        corpusHits = []
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
            let levels = snapshot.aiEvidenceLevels.values
            aiSecondRerankState = .completed(
                fullText: levels.filter { $0.contains("全文") }.count,
                abstractOnly: levels.filter { $0.contains("摘要") }.count,
                retained: snapshot.rankedWorks.count
            )
        }
    }

    func captureHistoryMutationContext() -> HistoryMutationContext {
        HistoryMutationContext(
            searchGeneration: searchGeneration,
            corpusGeneration: corpusAnalysisGeneration,
            historyID: currentHistoryID
        )
    }

    func isCurrentHistoryMutationContext(_ context: HistoryMutationContext) -> Bool {
        context.searchGeneration == searchGeneration
            && context.historyID == currentHistoryID
    }

    private func isCurrentCorpusMutationContext(_ context: HistoryMutationContext) -> Bool {
        isCurrentHistoryMutationContext(context)
            && context.corpusGeneration == corpusAnalysisGeneration
    }

    private func invalidateAsyncWork() {
        aiEnhancementTask?.cancel()
        aiEnhancementTask = nil
        advanceSearchGeneration()
        corpusAnalysisGeneration &+= 1
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
        aiEnhancementTask?.cancel()
        aiEnhancementTask = nil
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
        aiSearchNotice = nil
        pubMedNotice = nil
        searchTimingSummary = nil
        fullTextState = .idle
        fullTextDocument = nil
        passageHits = []
        passageQuery = ""
        corpusState = .idle
        corpusDocuments = [:]
        corpusHits = []
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
                merged.useLedger = current.useLedger
                currentHistoryRecord = merged
                publishedRecord = merged
            } else {
                currentHistoryRecord = result.record
                publishedRecord = result.record
            }
            publishStageHistorySummaries(result.index.summaries)
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
        if decisionFilter == .use {
            return useWorks
        }
        return works
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
        if let document = corpusDocuments[work.id],
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
            let plan = try await planAISearchWithSoftTimeout(
                description: displayQuery,
                configuration: configuration,
                currentSort: sort,
                currentFromYear: currentFromYear,
                currentOpenAccessOnly: openAccessOnly,
                timeoutSeconds: 6
            )
            try ensureSearchIsActive(generation)
            let planningSeconds = elapsedSeconds(since: planningStartedAt)

            aiRerankState = .fetchingCandidates
            let apiKey = CredentialStore.string(for: .openAlexAPIKey)
            guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AISearchPipelineError.openAlexKeyRequired
            }
            let candidateStartedAt = Date()
            let candidateResult = try await fetchAICandidates(
                plan: plan,
                apiKey: apiKey
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
            aiRankedWorks = candidates
            lastQuery = plan.searchQuery
            totalCount = candidates.count
            currentPage = 1
            isLoading = false
            applyLocalFastRanking(
                candidates,
                originalRequest: displayQuery,
                retrievalQuery: plan.searchQuery
            )
            totalCount = aiRankedWorks.count
            await showAIPage(1, analyze: false, persistStage: false)
            searchTimingSummary = "首屏 \(elapsedSeconds(since: searchStartedAt)) 秒 · AI 理解 \(planningSeconds) 秒 · OpenAlex \(candidateSeconds) 秒 · 临时候选"
            await commitFirstUsableHistoryStage(
                displayQuery: displayQuery,
                startedAt: searchStartedAt,
                generation: generation
            )
            guard generation == searchGeneration,
                  historyErrorMessage == nil else { return }
            analyzeVisiblePageInBackground()
            enrichVisibleAIPageFullTextInBackground(
                works: works,
                generation: generation
            )
            aiEnhancementTask = Task { [weak self] in
                guard let self else { return }
                await self.continueAIEnhancedRanking(
                    generation: generation,
                    candidates: candidates,
                    originalRequest: displayQuery,
                    retrievalQuery: plan.searchQuery,
                    configuration: configuration,
                    searchStartedAt: searchStartedAt
                )
            }
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

    private func continueAIEnhancedRanking(
        generation: Int,
        candidates: [Work],
        originalRequest: String,
        retrievalQuery: String,
        configuration: AIProviderConfiguration,
        searchStartedAt: Date
    ) async {
        do {
            try ensureSearchIsActive(generation)
            let coarseStartedAt = Date()
            let usedAIRanking = try await rerankCandidates(
                candidates,
                originalRequest: originalRequest,
                configuration: configuration
            )
            try ensureSearchIsActive(generation)
            let coarseSeconds = elapsedSeconds(since: coarseStartedAt)

            totalCount = aiRankedWorks.count
            let rankedResultsSeconds = elapsedSeconds(since: searchStartedAt)
            searchTimingSummary = usedAIRanking
                ? "首屏 \(rankedResultsSeconds) 秒 · AI 摘要精排 \(coarseSeconds) 秒"
                : "首屏 \(rankedResultsSeconds) 秒 · AI 粗排未返回 \(coarseSeconds) 秒 · 临时候选"
            await showAIPage(1, analyze: false)
            analyzeVisiblePageInBackground()

            guard !aiRankedWorks.isEmpty else {
                aiSearchNotice = "AI 已分析 \(candidates.count) 篇候选论文，但没有找到相关度达到要求的结果；当前保留临时候选。"
                applyLocalFastRanking(
                    candidates,
                    originalRequest: originalRequest,
                    retrievalQuery: retrievalQuery
                )
                await showAIPage(1, analyze: false)
                analyzeVisiblePageInBackground()
                return
            }

            let evidenceTiming = try await rerankWithFullTextEvidence(
                originalRequest: originalRequest,
                retrievalQuery: retrievalQuery,
                configuration: configuration
            )
            try ensureSearchIsActive(generation)
            totalCount = aiRankedWorks.count
            searchTimingSummary = usedAIRanking
                ? "首屏 \(rankedResultsSeconds) 秒 · AI 精排 \(coarseSeconds) 秒 · 证据初排 \(evidenceTiming.initial) 秒 · 全文补强 \(evidenceTiming.refinement) 秒"
                : "首屏 \(rankedResultsSeconds) 秒 · 临时候选 · 证据初排 \(evidenceTiming.initial) 秒 · 全文补强 \(evidenceTiming.refinement) 秒"
            await showAIPage(1, analyze: false)
            await analyzeCurrentPage()
        } catch is CancellationError {
            return
        } catch {
            do {
                try ensureSearchIsActive(generation)
                aiSecondRerankState = .failed(error.localizedDescription)
            } catch {
                return
            }
        }
    }

    private func applyLocalFastRanking(
        _ candidates: [Work],
        originalRequest: String,
        retrievalQuery: String
    ) {
        let tokens = Set(
            "\(originalRequest) \(retrievalQuery)"
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
        )
        let ranked: [(work: Work, score: Int)] = candidates.enumerated().map { index, work in
            let title = work.title.lowercased()
            let abstract = (work.abstractText ?? "").lowercased()
            let venue = work.venue.lowercased()
            var score = max(0, 50 - index)
            for token in tokens {
                if title.contains(token) { score += 12 }
                if abstract.contains(token) { score += 4 }
                if venue.contains(token) { score += 1 }
            }
            if work.abstractText != nil { score += 4 }
            if work.openAccess?.isOpenAccess == true { score += 2 }
            return (work: work, score: min(100, score))
        }
        .sorted { $0.score > $1.score }

        aiRankedWorks = ranked.map(\.work)
        aiScores = Dictionary(uniqueKeysWithValues: ranked.map { ($0.work.id, $0.score) })
        aiReasons = Dictionary(
            uniqueKeysWithValues: ranked.map {
                ($0.work.id, localPreviewReason(for: $0.work))
            }
        )
        aiEvidenceLevels = Dictionary(
            uniqueKeysWithValues: ranked.map { ($0.work.id, "临时候选") }
        )
        aiRerankState = .localReady(candidates: candidates.count)
        aiSecondRerankState = .idle
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
        apiKey: String?
    ) async throws -> (works: [Work], aiNotice: String?, pubMedNotice: String?) {
        let pageCount = Int(ceil(Double(aiCandidateLimit) / Double(aiCandidatePageSize)))
        let pages = await withTaskGroup(
            of: (page: Int, works: [Work], error: String?).self,
            returning: [(page: Int, works: [Work], error: String?)].self
        ) { group in
            for page in 1...pageCount {
                group.addTask {
                    await self.fetchCandidatePageWithSoftTimeout(
                        plan: plan,
                        apiKey: apiKey,
                        page: page,
                        seconds: 8
                    )
                }
            }
            var values: [(page: Int, works: [Work], error: String?)] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        var seen = Set<String>()
        let openAlexWorks = pages
            .sorted { $0.page < $1.page }
            .flatMap(\.works)
            .filter { seen.insert($0.id).inserted }

        let pubMedWorks = await fetchPubMedCandidates(
            query: plan.pubMedQuery ?? plan.searchQuery,
            fromYear: plan.fromYear,
            limit: aiCandidateLimit
        )
        let openAlexCapped = Array(openAlexWorks.prefix(aiCandidateLimit))
        let merged = Self.mergeDedup(primary: openAlexCapped, additional: pubMedWorks)
        // Keep every OpenAlex candidate and reserve pool slots for PubMed-only finds, so
        // PubMed's unique papers are not truncated away when OpenAlex already fills the limit.
        let addedFromPubMed = min(merged.count - openAlexCapped.count, aiCandidateLimit / 2)
        let candidates = Array(merged.prefix(openAlexCapped.count + addedFromPubMed))

        guard !candidates.isEmpty else {
            let errors = pages.compactMap(\.error)
            throw AISearchPipelineError.candidateFetch(
                errors.isEmpty ? "OpenAlex 和 PubMed 都没有返回候选论文" : errors.joined(separator: "；")
            )
        }

        let pubMedNotice = addedFromPubMed > 0
            ? "PubMed 为本次检索补充了 \(addedFromPubMed) 篇 OpenAlex 未覆盖的论文。"
            : nil
        let failedPages = pages.filter { $0.error != nil }.count
        let aiNotice = failedPages > 0
            ? "\(failedPages) 个 OpenAlex 候选批次失败，已用成功取得的 \(candidates.count) 篇继续分析。"
            : nil
        return (candidates, aiNotice, pubMedNotice)
    }

    /// Best-effort PubMed discovery. Failures return an empty list so OpenAlex results
    /// are never blocked by a PubMed error or timeout.
    private func fetchPubMedCandidates(
        query: String,
        fromYear: Int?,
        limit: Int
    ) async -> [Work] {
        let email = UserDefaults.standard
            .string(forKey: SettingsKeys.contactEmail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await pubMedClient.search(
                query: query,
                fromYear: fromYear,
                maxResults: limit,
                contactEmail: (email?.isEmpty == false) ? email : nil,
                timeout: 12
            )
        } catch {
            return []
        }
    }

    /// Merges an additional result set into a primary one, keeping all primary works and
    /// appending only additional works that don't already appear (by DOI, PMID, or title).
    private static func mergeDedup(primary: [Work], additional: [Work]) -> [Work] {
        var keys = Set<String>()
        for work in primary {
            for key in dedupKeys(work) { keys.insert(key) }
        }
        var result = primary
        for work in additional {
            let workKeys = dedupKeys(work)
            if workKeys.contains(where: { keys.contains($0) }) { continue }
            for key in workKeys { keys.insert(key) }
            result.append(work)
        }
        return result
    }

    private static func dedupKeys(_ work: Work) -> [String] {
        var keys: [String] = []
        if let doi = work.normalizedDOI?.lowercased(), !doi.isEmpty {
            keys.append("doi:" + doi)
        }
        if let pmid = work.normalizedPMID, !pmid.isEmpty {
            keys.append("pmid:" + pmid)
        }
        let title = dedupTitleKey(work.title)
        if !title.isEmpty { keys.append("title:" + title) }
        return keys
    }

    private static func dedupTitleKey(_ title: String) -> String {
        title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func fetchCandidatePageWithSoftTimeout(
        plan: AISearchPlan,
        apiKey: String?,
        page: Int,
        seconds: Int
    ) async -> (page: Int, works: [Work], error: String?) {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            nonisolated(unsafe) var didResume = false

            func resumeOnce(_ value: (page: Int, works: [Work], error: String?)) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: value)
            }

            Task.detached(priority: .userInitiated) {
                do {
                    let response = try await self.client.search(
                        query: plan.searchQuery,
                        sort: plan.sort,
                        fromYear: plan.fromYear,
                        openAccessOnly: plan.openAccessOnly,
                        apiKey: apiKey,
                        page: page,
                        perPage: self.aiCandidatePageSize,
                        timeout: TimeInterval(seconds),
                        maxAttempts: 1
                    )
                    resumeOnce((page, response.results, nil))
                } catch {
                    resumeOnce((page, [], error.localizedDescription))
                }
            }

            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(for: .seconds(seconds))
                resumeOnce((page, [], "OpenAlex 候选请求超时"))
            }
        }
    }

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
        await showAIPage(page)
    }

    private func rerankCandidates(
        _ candidates: [Work],
        originalRequest: String,
        configuration: AIProviderConfiguration
    ) async throws -> Bool {
        let modelCandidates = Array(candidates.prefix(aiCoarseRankingLimit))
        let deferredCandidates = Array(candidates.dropFirst(modelCandidates.count))
        guard !modelCandidates.isEmpty else { return false }

        var ranked: [(work: Work, score: Int, relevant: Bool, reason: String, order: Int)] = []
        var completed = 0
        aiRerankState = .ranking(completed: 0, total: modelCandidates.count)

        let batches = stride(
            from: 0,
            to: modelCandidates.count,
            by: aiCoarseRankingBatchSize
        ).map { start in
            let end = min(start + aiCoarseRankingBatchSize, modelCandidates.count)
            return (start: start, values: Array(modelCandidates[start..<end]))
        }
        let planner = aiQueryPlanner
        var failedBatches = 0
        await withTaskGroup(
            of: (start: Int, works: [Work], results: [AIRankedCandidate]?).self
        ) { group in
            for batch in batches {
                group.addTask {
                    do {
                        let results = try await SearchStore.rankBatchWithSoftTimeout(
                            planner: planner,
                            description: originalRequest,
                            candidates: batch.values,
                            configuration: configuration,
                            seconds: 18
                        )
                        return (batch.start, batch.values, results)
                    } catch {
                        do {
                            try await Task.sleep(for: .seconds(2))
                            let results = try await SearchStore.rankBatchWithSoftTimeout(
                                planner: planner,
                                description: originalRequest,
                                candidates: batch.values,
                                configuration: configuration,
                                seconds: 18
                            )
                            return (batch.start, batch.values, results)
                        } catch {
                            return (batch.start, batch.values, nil)
                        }
                    }
                }
            }

            for await batch in group {
                if let results = batch.results {
                    let byIndex = Dictionary(
                        uniqueKeysWithValues: results.map { ($0.index, $0) }
                    )
                    for (localIndex, work) in batch.works.enumerated() {
                        guard let result = byIndex[localIndex] else { continue }
                        let score = min(100, max(0, result.score))
                        let reason = normalizedContentSummaryReason(
                            result.reason,
                            fallback: localPreviewReason(for: work)
                        )
                        ranked.append(
                            (
                                work: work,
                                score: score,
                                relevant: result.relevant,
                                reason: reason,
                                order: batch.start + localIndex
                            )
                        )
                    }
                } else {
                    failedBatches += 1
                }
                completed += batch.works.count
                aiRerankState = .ranking(completed: completed, total: modelCandidates.count)
            }
        }

        guard !ranked.isEmpty else {
            aiSearchNotice = "AI 粗排暂未返回，当前只显示临时候选；不会把它当作最终 AI 结果。"
            aiRerankState = .failed(
                message: "AI 粗排暂未返回",
                candidates: candidates.count
            )
            return false
        }
        if failedBatches > 0 {
            aiSearchNotice = "有 \(failedBatches) 个 AI 粗排批次失败，已保留其他成功批次的结果。"
        }

        let retained = ranked
            .filter { $0.relevant && $0.score >= 55 }
            .sorted {
                if $0.score == $1.score { return $0.order < $1.order }
                return $0.score > $1.score
            }
        let retainedIDs = Set(retained.map(\.work.id))
        let remaining = candidates.filter { !retainedIDs.contains($0.id) }
        aiRankedWorks = retained.map(\.work) + remaining

        var reasons = aiReasons
        var scores = aiScores
        var levels = aiEvidenceLevels
        for result in retained {
            reasons[result.work.id] = normalizedContentSummaryReason(
                result.reason,
                fallback: localPreviewReason(for: result.work)
            )
            scores[result.work.id] = result.score
            levels[result.work.id] = "AI 摘要精排"
        }
        for work in remaining {
            if levels[work.id] == nil {
                levels[work.id] = "临时候选"
            }
            if reasons[work.id] == nil {
                reasons[work.id] = localPreviewReason(for: work)
            }
        }
        aiReasons = reasons
        aiScores = scores
        aiEvidenceLevels = levels
        if failedBatches == 0, !deferredCandidates.isEmpty {
            aiSearchNotice = "AI 已优先精排前 \(modelCandidates.count) 篇；其余候选仍保留在后面，避免漏掉潜在相关论文。"
        } else if retained.count < candidates.count {
            aiSearchNotice = "AI 已精排 \(retained.count) 篇；其余候选仍保留在后面，避免漏掉潜在相关论文。"
        }
        aiRerankState = .completed(
            candidates: candidates.count,
            retained: aiRankedWorks.count
        )
        return true
    }

    private nonisolated static func rankBatchWithSoftTimeout(
        planner: AIQueryPlanner,
        description: String,
        candidates: [Work],
        configuration: AIProviderConfiguration,
        seconds: Int
    ) async throws -> [AIRankedCandidate] {
        try await withThrowingTaskGroup(of: [AIRankedCandidate].self) { group in
            group.addTask {
                try await planner.rankBatch(
                    description: description,
                    candidates: candidates,
                    configuration: configuration
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AISearchPipelineError.coarseRanking("AI 粗排请求超时")
            }
            guard let first = try await group.next() else {
                throw AISearchPipelineError.coarseRanking("AI 粗排无响应")
            }
            group.cancelAll()
            return first
        }
    }

    private func rerankWithFullTextEvidence(
        originalRequest: String,
        retrievalQuery: String,
        configuration: AIProviderConfiguration
    ) async throws -> (initial: String, refinement: String) {
        try Task.checkCancellation()
        let initialStartedAt = Date()
        let fallbackWorks = aiRankedWorks
        let candidates = Array(aiRankedWorks.prefix(aiEvidenceCandidateLimit))
        guard !candidates.isEmpty else {
            aiSecondRerankState = .completed(fullText: 0, abstractOnly: 0, retained: 0)
            return ("0.0", "0.0")
        }

        let apiKey = CredentialStore.string(for: .openAlexAPIKey)
        let semanticScholarAPIKey = CredentialStore.string(for: .semanticScholarAPIKey)
        let contactEmail = UserDefaults.standard.string(forKey: SettingsKeys.contactEmail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fullTextService = fullTextService
        var documentsByID: [String: FullTextDocument] = [:]
        let evidenceQuery = Self.evidenceRetrievalQuery(
            originalRequest: originalRequest,
            retrievalQuery: retrievalQuery
        )
        let initialInputs = makeEvidenceInputs(
            candidates: candidates,
            documentsByID: documentsByID,
            retrievalQuery: evidenceQuery
        )
        aiSecondRerankState = .rankingEvidence(
            completed: initialInputs.count,
            total: initialInputs.count
        )
        let initialRanked = fallbackEvidenceRanking(initialInputs)
        applyEvidenceRanking(initialRanked, preserving: fallbackWorks)
        totalCount = aiRankedWorks.count
        await showAIPage(1, analyze: false)
        analyzeVisiblePageInBackground()
        let initialSeconds = elapsedSeconds(since: initialStartedAt)

        let fullTextCandidates = candidates
        guard !fullTextCandidates.isEmpty else { return (initialSeconds, "0.0") }
        let refinementStartedAt = Date()
        var completed = 0
        aiSecondRerankState = .refiningFullText(
            completed: 0,
            total: fullTextCandidates.count
        )

        await withTaskGroup(of: (Work, FullTextDocument?).self) { group in
            for work in fullTextCandidates {
                group.addTask {
                    let document = await Self.loadFullTextWithSoftTimeout(
                        service: fullTextService,
                        work: work,
                        apiKey: apiKey,
                        contactEmail: contactEmail,
                        semanticScholarAPIKey: semanticScholarAPIKey,
                        seconds: 6
                    )
                    return (work, document)
                }
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
                }
                completed += 1
                aiSecondRerankState = .refiningFullText(
                    completed: completed,
                    total: fullTextCandidates.count
                )
            }
        }

        try Task.checkCancellation()

        let fullTextPairs = fullTextCandidates.compactMap { work -> (work: Work, document: FullTextDocument)? in
            guard let document = documentsByID[work.id] else { return nil }
            guard document.source.isFullText else { return nil }
            return (work, document)
        }
        for pair in fullTextPairs {
            aiFullTextDocuments[pair.work.id] = pair.document
        }
        startFullTextReviewSummaryGeneration(
            for: fullTextPairs,
            configuration: configuration
        )

        let enhancedInputs = makeEvidenceInputs(
            candidates: candidates,
            documentsByID: documentsByID,
            retrievalQuery: evidenceQuery
        )
        aiSecondRerankState = .rankingEvidence(
            completed: enhancedInputs.count,
            total: enhancedInputs.count
        )
        let enhancedRanked = fallbackEvidenceRanking(enhancedInputs)
        let enhancedByID = Dictionary(
            uniqueKeysWithValues: enhancedRanked.map { ($0.work.id, $0) }
        )
        let mergedRanked = initialRanked.map { enhancedByID[$0.work.id] ?? $0 }
        applyEvidenceRanking(mergedRanked, preserving: fallbackWorks)
        return (initialSeconds, elapsedSeconds(since: refinementStartedAt))
    }

    private nonisolated static func loadFullTextWithSoftTimeout(
        service: FullTextService,
        work: Work,
        apiKey: String?,
        contactEmail: String?,
        semanticScholarAPIKey: String?,
        seconds: Int
    ) async -> FullTextDocument? {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            nonisolated(unsafe) var didResume = false

            func resumeOnce(_ document: FullTextDocument?) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(returning: document)
            }

            Task.detached(priority: .utility) {
                let document = try? await service.load(
                    work: work,
                    apiKey: apiKey,
                    contactEmail: contactEmail,
                    semanticScholarAPIKey: semanticScholarAPIKey
                )
                if let document,
                   fullTextDocument(document, matches: work) {
                    resumeOnce(document)
                } else {
                    if document?.source.isFullText == true {
                        await service.clearCache(workID: work.id)
                    }
                    resumeOnce(nil)
                }
            }

            Task.detached(priority: .utility) {
                try? await Task.sleep(for: .seconds(seconds))
                resumeOnce(nil)
            }
        }
    }

    private func makeEvidenceInputs(
        candidates: [Work],
        documentsByID: [String: FullTextDocument],
        retrievalQuery: String
    ) -> [AIEvidenceRankingInput] {
        candidates.map { work in
            let document = documentsByID[work.id]
            let passages: [PassageHit]
            if let document, document.source.isFullText {
                passages = HybridRetriever.search(
                    query: retrievalQuery,
                    paragraphs: document.paragraphs,
                    limit: 3
                )
            } else {
                passages = []
            }
            return AIEvidenceRankingInput(
                work: work,
                abstract: work.abstractText,
                passages: passages,
                source: document?.source
            )
        }
    }

    private func fallbackEvidenceRanking(
        _ inputs: [AIEvidenceRankingInput]
    ) -> [EvidenceRankResult] {
        inputs.enumerated().map { index, input in
            let baseScore = aiScores[input.work.id] ?? max(55, 80 - index)
            let evidenceBonus = input.hasFullTextEvidence ? 8 : (input.abstract == nil ? -8 : 0)
            let score = min(100, max(55, baseScore + evidenceBonus))
            return (
                work: input.work,
                score: score,
                relevant: true,
                reason: evidenceReason(for: input),
                hasFullText: input.hasFullTextEvidence,
                order: index
            )
        }
    }

    private func localPreviewReason(for work: Work) -> String {
        "摘要简述：\(abstractOnlyPaperSummary(for: work))"
    }

    private func evidenceReason(for input: AIEvidenceRankingInput) -> String {
        if let existing = aiReasons[input.work.id],
           !isGenericRankingReason(existing) {
            return existing
        }
        if let passage = input.passages.first {
            let summary = contentSummary(
                for: input.work,
                evidenceText: passage.paragraph.text
            )
            return "全文简述：\(summary)"
        }
        return "摘要简述：\(abstractOnlyPaperSummary(for: input.work))"
    }

    private func normalizedContentSummaryReason(
        _ reason: String,
        fallback: String
    ) -> String {
        let clean = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !isGenericRankingReason(clean) else {
            return fallback
        }
        if clean.hasPrefix("论文简述：")
            || clean.hasPrefix("摘要简述：")
            || clean.hasPrefix("全文简述：") {
            return clean
        }
        return "论文简述：\(clean)"
    }

    private func isGenericRankingReason(_ reason: String) -> Bool {
        reason.hasPrefix("本地快速排序")
            || reason.hasPrefix("本地证据排序")
            || reason.hasPrefix("临时候选：标题")
            || reason.hasPrefix("摘要预览")
            || reason.hasPrefix("全文要点")
            || reason.hasPrefix("摘要要点")
            || reason.contains("与当前检索主题相关")
            || reason.contains("可用于初步判断研究范围")
            || reason.contains("可作为当前检索主题的候选证据")
            || reason.contains("可用于判断与当前问题的相关性")
    }

    private func contentSummary(for work: Work, evidenceText: String?) -> String {
        let cleanEvidence = evidenceText?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let cleanEvidence, !cleanEvidence.isEmpty {
            return "\(paperSummaryPrefix(for: work.title))：\(shortEvidenceSentence(cleanEvidence))"
        }

        if work.abstractText == nil {
            return "当前只有标题和元数据，暂时无法总结具体结论，需进一步读取摘要或全文。"
        }
        return "本文围绕题名所示研究问题展开，当前摘要信息不足，需打开原文核对具体结论。"
    }

    private func abstractOnlyPaperSummary(for work: Work) -> String {
        let title = work.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let abstract = work.abstractText,
              !abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "本文围绕“\(String(title.prefix(80)))”展开；当前缺少摘要，需读取原文核对具体内容。"
        }

        let lowerTitle = title.lowercased()
        let summarySubject = shortTitleSubject(title)
        let focus = abstractFocusTerms(from: "\(title) \(abstract)")
        let focusText = focus.isEmpty ? "" : "，重点涉及\(focus.joined(separator: "、"))"

        if lowerTitle.contains("systematic review")
            || lowerTitle.contains("meta-analysis")
            || lowerTitle.contains("scoping review")
            || lowerTitle.contains("review") {
            return "本文综述\(summarySubject)\(focusText)，用于梳理该领域的研究证据和主要问题。"
        }
        if lowerTitle.contains("trial")
            || lowerTitle.contains("cohort")
            || lowerTitle.contains("case-control")
            || lowerTitle.contains("cross-sectional")
            || abstract.lowercased().contains("participants")
            || abstract.lowercased().contains("patients") {
            return "本文基于临床或观察性数据研究\(summarySubject)\(focusText)，用于评估相关因素、结局或关联。"
        }
        if lowerTitle.contains("development")
            || lowerTitle.contains("validation")
            || lowerTitle.contains("questionnaire")
            || abstract.lowercased().contains("validated") {
            return "本文开发或验证与\(summarySubject)相关的测量工具或方法\(focusText)。"
        }
        return "本文研究\(summarySubject)\(focusText)，摘要可用于初步了解研究问题，具体方法和结果仍需核对全文。"
    }

    private func shortTitleSubject(_ title: String) -> String {
        let clean = title
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "该主题" }
        return "“\(String(clean.prefix(90)))”"
    }

    private func abstractFocusTerms(from text: String) -> [String] {
        let mappings: [(String, String)] = [
            ("national drug code", "National Drug Codes"),
            ("ndc", "NDC"),
            ("gastrointestinal", "胃肠道症状"),
            ("adverse drug", "药物不良事件"),
            ("claims", "医保/索赔数据库"),
            ("observational", "观察性数据库"),
            ("opioid", "阿片类药物"),
            ("autism", "自闭症"),
            ("camouflaging", "社交伪装"),
            ("masking", "掩饰行为"),
            ("diagnosis", "诊断"),
            ("polypharmacy", "多重用药"),
            ("drug code", "药品编码"),
            ("terminolog", "标准化术语")
        ]
        let lower = text.lowercased()
        var values: [String] = []
        for (needle, label) in mappings where lower.contains(needle) && !values.contains(label) {
            values.append(label)
            if values.count == 3 { break }
        }
        return values
    }

    private func shortEvidenceSentence(_ text: String) -> String {
        let separators = CharacterSet(charactersIn: ".!?。！？\n")
        let firstSentence = text
            .components(separatedBy: separators)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = firstSentence?.isEmpty == false ? firstSentence! : text
        return String(value.prefix(120))
    }

    private func paperSummaryPrefix(for title: String) -> String {
        let lower = title.lowercased()
        if lower.contains("review")
            || lower.contains("meta-analysis")
            || lower.contains("systematic") {
            return "本文综述"
        }
        if lower.contains("trial")
            || lower.contains("cohort")
            || lower.contains("patients")
            || lower.contains("case-control") {
            return "本文基于临床或样本研究"
        }
        return "本文研究"
    }

    private func applyEvidenceRanking(
        _ ranked: [EvidenceRankResult],
        preserving fallbackWorks: [Work]
    ) {
        let retained = ranked
            .filter { $0.relevant && $0.score >= 55 }
            .sorted {
                if $0.score == $1.score { return $0.order < $1.order }
                return $0.score > $1.score
            }
        let retainedIDs = Set(retained.map(\.work.id))
        let remaining = fallbackWorks.filter { !retainedIDs.contains($0.id) }
        aiRankedWorks = retained.map(\.work) + remaining

        var reasons = aiReasons
        var scores = aiScores
        var levels = aiEvidenceLevels
        for result in retained {
            let cleanReason = result.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanReason.isEmpty {
                reasons[result.work.id] = cleanReason
            } else if reasons[result.work.id] == nil {
                reasons[result.work.id] = localPreviewReason(for: result.work)
            }
            scores[result.work.id] = result.score
            levels[result.work.id] = result.hasFullText ? "全文段落精排" : "仅摘要精排"
        }
        for work in remaining where levels[work.id] == nil {
            levels[work.id] = "AI 摘要粗排"
        }
        aiReasons = reasons
        aiScores = scores
        aiEvidenceLevels = levels

        let fullTextCount = retained.filter(\.hasFullText).count
        aiSecondRerankState = .completed(
            fullText: fullTextCount,
            abstractOnly: retained.count - fullTextCount,
            retained: aiRankedWorks.count
        )
    }

    private func showAIPage(
        _ page: Int,
        analyze: Bool = true,
        persistStage: Bool = true
    ) async {
        guard page >= 1 else { return }
        let start = (page - 1) * pageSize
        guard start < aiRankedWorks.count || (page == 1 && aiRankedWorks.isEmpty) else {
            return
        }
        let end = min(start + pageSize, aiRankedWorks.count)
        works = start < end ? Array(aiRankedWorks[start..<end]) : []
        currentPage = page
        evidence = EvidenceExtractor.extract(query: lastQuery, works: works)
        selection = works.first?.id
        fullTextState = .idle
        fullTextDocument = nil
        passageHits = []
        passageQuery = lastQuery
        corpusState = .idle
        corpusDocuments = [:]
        corpusHits = []
        if persistStage {
            scheduleCompletedStageSave()
        }
        if analyze {
            await analyzeCurrentPage()
        }
        if persistStage {
            enrichVisibleAIPageFullTextInBackground(
                works: works,
                generation: searchGeneration
            )
        }
    }

    private func enrichVisibleAIPageFullTextInBackground(
        works pageWorks: [Work],
        generation: Int
    ) {
        let context = captureHistoryMutationContext()
        guard context.searchGeneration == generation else { return }
        let candidates = pageWorks.filter { work in
            aiFullTextDocuments[work.id] == nil
                && !fullTextReviewSummaryInProgress.contains(work.id)
                && !aiVisiblePageFullTextInProgress.contains(work.id)
        }
        guard !candidates.isEmpty else { return }

        for work in candidates {
            aiVisiblePageFullTextInProgress.insert(work.id)
            aiVisiblePageFullTextFailures.removeValue(forKey: work.id)
        }

        let apiKey = CredentialStore.string(for: .openAlexAPIKey)
        let semanticScholarAPIKey = CredentialStore.string(for: .semanticScholarAPIKey)
        let contactEmail = UserDefaults.standard.string(forKey: SettingsKeys.contactEmail)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fullTextService = fullTextService
        let configuration = AIProviderConfiguration.load(activeAIProvider)

        Task { [weak self] in
            guard let self else { return }
            defer {
                if self.isCurrentHistoryMutationContext(context) {
                    for work in candidates {
                        self.aiVisiblePageFullTextInProgress.remove(work.id)
                    }
                }
            }
            var fullTextPairs: [(work: Work, document: FullTextDocument)] = []

            await withTaskGroup(of: (Work, FullTextDocument?).self) { group in
                for work in candidates {
                    group.addTask {
                        let document = await Self.loadFullTextWithSoftTimeout(
                            service: fullTextService,
                            work: work,
                            apiKey: apiKey,
                            contactEmail: contactEmail,
                            semanticScholarAPIKey: semanticScholarAPIKey,
                            seconds: 14
                        )
                        return (work, document)
                    }
                }

                for await (work, document) in group {
                    guard self.isCurrentHistoryMutationContext(context) else {
                        group.cancelAll()
                        return
                    }

                    defer {
                        self.aiVisiblePageFullTextInProgress.remove(work.id)
                    }

                    guard let document,
                          document.source.isFullText,
                          Self.fullTextDocument(document, matches: work) else {
                        self.aiVisiblePageFullTextFailures[work.id] =
                            "No accessible full text was found automatically for this paper, so an AI summary could not be generated."
                        continue
                    }

                    self.aiFullTextDocuments[work.id] = document
                    self.aiVisiblePageFullTextFailures.removeValue(forKey: work.id)
                    fullTextPairs.append((work, document))

                    var levels = self.aiEvidenceLevels
                    if levels[work.id] == nil
                        || levels[work.id] == "仅摘要精排"
                        || levels[work.id] == "AI 摘要粗排" {
                        levels[work.id] = "全文已读取"
                        self.aiEvidenceLevels = levels
                    }
                }
            }

            guard self.isCurrentHistoryMutationContext(context),
                  !fullTextPairs.isEmpty else {
                return
            }
            self.startFullTextReviewSummaryGeneration(
                for: fullTextPairs,
                configuration: configuration
            )
            self.scheduleCompletedStageSave()
        }
    }

    private func analyzeVisiblePageInBackground() {
        let context = captureHistoryMutationContext()
        Task {
            guard isCurrentHistoryMutationContext(context) else { return }
            await analyzeCurrentPage()
        }
    }

    private func ensureSearchIsActive(_ generation: Int) throws {
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
            await fullTextService.clearCache(workID: work.id)
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
                    await fullTextService.clearCache(workID: work.id)
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

    func analyzeCurrentPage() async {
        let candidates = works
        guard !candidates.isEmpty else { return }
        corpusAnalysisGeneration &+= 1
        let context = captureHistoryMutationContext()
        corpusState = .loading(completed: 0, total: candidates.count)
        corpusDocuments = [:]
        corpusHits = []
        var failures: [String] = []

        var completed = 0
        await withTaskGroup(of: (Work, FullTextDocument?, String?).self) { group in
            for work in candidates {
                group.addTask {
                    do {
                        let document = try await self.fullTextService.loadForPageAnalysis(
                            work: work
                        )
                        return (work, document, nil)
                    } catch {
                        return (work, nil, error.localizedDescription)
                    }
                }
            }

            for await (work, document, error) in group {
                guard isCurrentCorpusMutationContext(context) else {
                    group.cancelAll()
                    return
                }
                if let document,
                   !document.source.isFullText || Self.fullTextDocument(document, matches: work) {
                    corpusDocuments[work.id] = document
                } else if let error {
                    failures.append("\(work.title)：\(error)")
                }
                completed += 1
                corpusState = .loading(completed: completed, total: candidates.count)
            }
        }

        guard isCurrentCorpusMutationContext(context) else { return }
        searchCorpus()
        if corpusDocuments.isEmpty {
            corpusState = .failed(
                failures.isEmpty ? "没有取得可分析的正文或摘要。" : failures.joined(separator: "\n")
            )
        } else {
            corpusState = .loaded
        }
    }

    func searchCorpus() {
        let cleanQuery = passageQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeQuery = cleanQuery.isEmpty ? lastQuery : cleanQuery
        corpusHits = works.flatMap { work -> [CorpusPassageHit] in
            guard let document = corpusDocuments[work.id] else { return [] }
            return HybridRetriever.search(
                query: activeQuery,
                paragraphs: document.paragraphs,
                limit: 4
            ).map {
                CorpusPassageHit(work: work, document: document, passage: $0)
            }
        }
        .sorted {
            if $0.passage.score == $1.passage.score {
                return ($0.work.publicationYear ?? 0) > ($1.work.publicationYear ?? 0)
            }
            return $0.passage.score > $1.passage.score
        }
        .prefix(20)
        .map { $0 }
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
        if !corpusHits.isEmpty {
            let body = corpusHits.enumerated().map { index, hit in
                "## [\(index + 1)] \(hit.work.title)\n\n"
                    + "> \(hit.passage.paragraph.text)\n\n"
                    + "- 定位：\(hit.passage.paragraph.locator)\n"
                    + "- 来源：\(hit.document.source.title)\n"
                    + "- 年份：\(hit.work.publicationYear.map(String.init) ?? "未知")\n"
                    + "- 链接：\(hit.document.sourceURL ?? hit.work.landingPageURL?.absoluteString ?? hit.work.id)"
            }.joined(separator: "\n\n")
            return "# RagBio 证据报告\n\n"
                + "**检索主题：** \(activeQuery)\n\n"
                + "**方法：** 从 \(corpusDocuments.count) 篇论文的全文或摘要中进行本机混合检索；以下均为原文，不包含模型补写。\n\n"
                + body
        }
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
        let pattern = #"第\s*(\d+)\s*段"#
        guard let range = locator.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let match = String(locator[range])
        return Int(match.replacingOccurrences(of: #"\D"#, with: "", options: .regularExpression))
    }

    private func sourcePage(from locator: String) -> Int? {
        let pattern = #"第\s*(\d+)\s*页"#
        guard let range = locator.range(of: pattern, options: .regularExpression) else {
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
