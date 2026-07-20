import AppKit
import SwiftUI
import Translation

struct ContentView: View {
    @ObservedObject var store: SearchStore
    @ObservedObject var reviewJobs: ReviewJobCoordinator

    init(store: SearchStore, reviewJobs: ReviewJobCoordinator) {
        self.store = store
        self.reviewJobs = reviewJobs
    }

    @MainActor
    init(store: SearchStore) {
        self.init(store: store, reviewJobs: ReviewJobCoordinator())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if #available(macOS 14.0, *) {
                    SettingsLink {
                        Label("设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 16)
                } else {
                    Button {
                        NSApp.sendAction(
                            Selector(("showPreferencesWindow:")),
                            to: nil,
                            from: nil
                        )
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 16)
                }
            }
            .padding(.vertical, 8)

            Divider()

            HSplitView {
                SidebarView(store: store, reviewJobs: reviewJobs)
                    .frame(minWidth: 310, idealWidth: 390, maxWidth: 460, maxHeight: .infinity)
                Group {
                    if reviewJobs.presentedJob != nil {
                        ReviewWorkspaceView(coordinator: reviewJobs)
                    } else {
                        DetailPane(store: store)
                    }
                }
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $reviewJobs.confirmation) { confirmation in
            ReviewJobConfirmationSheet(
                confirmation: confirmation,
                coordinator: reviewJobs
            )
        }
    }
}

private struct SidebarView: View {
    @ObservedObject var store: SearchStore
    @ObservedObject var reviewJobs: ReviewJobCoordinator

    var body: some View {
        VStack(spacing: 0) {
            SearchHeader(store: store)
                .padding(16)
                .zIndex(20)

            Divider()

            if store.isLoading && store.works.isEmpty {
                Spacer()
                ProgressView(aiLoadingMessage)
                Spacer()
            } else if let error = store.errorMessage, store.works.isEmpty {
                EmptyStateView(
                    title: "检索失败",
                    systemImage: "wifi.exclamationmark",
                    description: error
                ) {
                    Button("重试") {
                        Task { await store.search() }
                    }
                }
            } else if store.works.isEmpty {
                EmptyStateView(
                    title: "检索学术文献",
                    systemImage: "books.vertical",
                    description: "输入主题、疾病、基因或方法名称。结果直接来自 OpenAlex。"
                )
            } else {
                resultsList
            }
        }
    }

    private var aiLoadingMessage: String {
        switch store.aiSecondRerankState {
        case let .fetchingEvidence(completed, total):
            return "正在准备摘要与缓存证据 \(completed)/\(total)…"
        case .rankingEvidence:
            return "AI 正在精排第 \(store.currentPage) 页全文证据…"
        case let .refiningFullText(completed, total):
            return "结果已可用，后台补强全文 \(completed)/\(total)…"
        default:
            break
        }
        switch store.aiRerankState {
        case .fetchingCandidates:
            return "正在获取最多 60 篇候选论文…"
        case let .localReady(candidates):
            return "已恢复 \(candidates) 篇历史候选；重新检索后会按摘要排序…"
        case let .ranking(completed, total):
            return "AI 正在按全部摘要排序 \(completed)/\(total)…"
        case let .failed(_, candidates):
            return "候选排序失败，当前保留 \(candidates) 篇历史结果…"
        default:
            return "正在检索 OpenAlex…"
        }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("第 \(store.currentPage) 页 · \(store.visibleResultRange)")
                Spacer()
                switch store.corpusState {
                case let .loading(completed, total):
                    ProgressView(value: Double(completed), total: Double(total))
                        .frame(width: 70)
                    Text("分析本页 \(completed)/\(total)")
                case .loaded:
                    Label("本页已分析", systemImage: "checkmark.circle")
                case .failed:
                    Label("本页分析失败", systemImage: "exclamationmark.triangle")
                default:
                    Text("等待分析")
                }
                switch store.aiSecondRerankState {
                case let .completed(fullText, abstractOnly, retained):
                    Text("证据精排 \(fullText + abstractOnly) 篇 · 全部保留 \(retained) 篇")
                default:
                    switch store.aiRerankState {
                    case let .localReady(candidates):
                        Text("已恢复 \(candidates) 篇历史候选")
                    case let .completed(candidates, retained):
                        Text("AI 摘要排序 \(candidates) 篇 · 全部保留 \(retained) 篇")
                    case let .failed(_, candidates):
                        Text("候选排序未完成 · 当前保留 \(candidates) 篇")
                    default:
                        Text("约 \(store.totalCount.formatted()) 条结果")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)

            HStack(spacing: 12) {
                StatusLegendItem(systemName: "lock.open", color: .green, text: "开放获取")
                StatusLegendItem(systemName: "text.quote", color: .blue, text: "有摘要")
                StatusLegendItem(systemName: "doc.text", color: .purple, text: "可尝试全文")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 7)

            ScanDecisionFilterBar(store: store, reviewJobs: reviewJobs)
                .padding(.horizontal, 16)
                .padding(.bottom, 7)

            List(selection: Binding(
                    get: { store.selection },
                    set: { store.select(workID: $0) }
                )) {
                ForEach(store.filteredWorks) { work in
                    WorkRow(
                        work: work,
                        translatedTitle: store.isTranslationVisible(for: work.id)
                            ? store.translatedTitles[work.id]
                            : nil,
                        aiScore: store.aiScores[work.id],
                        aiReason: store.aiReasons[work.id],
                        aiEvidenceLevel: store.aiEvidenceLevels[work.id],
                        decision: store.decision(for: work)
                    ) { decision in
                        store.setScanDecision(decision, for: work)
                    }
                        .tag(work.id)
                }

                VStack(spacing: 10) {
                    Text("已到第 \(store.currentPage) 页底部")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("上一页", systemImage: "chevron.left") {
                            Task { await store.goToPage(store.currentPage - 1) }
                        }
                        .disabled(!store.canGoToPreviousPage)

                        Text("第 \(store.currentPage) / \(store.totalPages) 页")
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 90)

                        Button("下一页", systemImage: "chevron.right") {
                            Task { await store.goToPage(store.currentPage + 1) }
                        }
                        .disabled(!store.canGoToNextPage)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }
            .listStyle(.sidebar)
            .overlay(alignment: .top) {
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: Capsule())
                }
            }
        }
    }
}

private struct SearchHeader: View {
    @ObservedObject var store: SearchStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("RagBio")
                    .font(.title2.bold())
                Text("可追溯的学术证据检索")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SearchHistoryField(store: store)

            if store.isRefreshingHistory {
                Text("Refreshing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch store.aiRerankState {
            case .fetchingCandidates:
                Label("正在获取最多 60 篇候选论文", systemImage: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case let .localReady(candidates):
                Label(
                    "已恢复 \(candidates) 篇历史候选；重新检索后会按全部摘要排序",
                    systemImage: "bolt"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            case let .ranking(completed, total):
                HStack {
                    ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    Text("AI 摘要排序 \(completed)/\(total)")
                        .font(.caption.monospacedDigit())
                }
            case let .completed(candidates, retained):
                Label(
                    "AI 已按全部摘要排序 \(candidates) 篇候选，列表保留 \(retained) 篇",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
                .foregroundStyle(.green)
            case let .failed(message, candidates):
                Label(
                    "\(message)，当前保留 \(candidates) 篇候选",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            case .idle:
                EmptyView()
            }

            switch store.aiSecondRerankState {
            case let .fetchingEvidence(completed, total):
                HStack {
                    ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    Text("准备证据 \(completed)/\(total)")
                        .font(.caption.monospacedDigit())
                }
            case .rankingEvidence:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("第 \(store.currentPage) 页 AI 全文精排中…")
                        .font(.caption)
                }
            case let .refiningFullText(completed, total):
                HStack {
                    ProgressView(value: Double(completed), total: Double(max(total, 1)))
                    Text("结果已显示 · 后台补全文 \(completed)/\(total)")
                        .font(.caption.monospacedDigit())
                }
            case let .completed(fullText, abstractOnly, retained):
                Label(
                    "第 \(store.currentPage) 页 AI 全文精排完成：\(fullText) 篇使用全文段落，\(abstractOnly) 篇仅用摘要；列表仍保留 \(retained) 篇",
                    systemImage: "text.magnifyingglass"
                )
                .font(.caption)
                .foregroundStyle(.green)
            case let .failed(message):
                Label(
                    message,
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            case .idle:
                EmptyView()
            }

            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let historyError = store.historyErrorMessage {
                Label(historyError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let exportMessage = store.exportMessage {
                Label(exportMessage, systemImage: "square.and.arrow.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let notice = store.aiSearchNotice {
                let isWarning = notice.contains("失败")
                    || notice.contains("超时")
                    || notice.contains("无法")
                Label(
                    notice,
                    systemImage: isWarning ? "exclamationmark.circle" : "info.circle"
                )
                    .font(.caption)
                    .foregroundStyle(isWarning ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let pubMed = store.pubMedNotice {
                Label(pubMed, systemImage: "plus.magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let timing = store.searchTimingSummary {
                Label(timing, systemImage: "timer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Picker("排序", selection: $store.sort) {
                    ForEach(SearchSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .labelsHidden()

                Toggle("仅开放获取", isOn: $store.openAccessOnly)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }

            HStack {
                Toggle("起始年份", isOn: $store.fromYearEnabled)
                    .toggleStyle(.checkbox)
                    .font(.caption)

                Picker("年份", selection: $store.fromYear) {
                    ForEach(
                        Array((1900...Calendar.current.component(.year, from: Date())).reversed()),
                        id: \.self
                    ) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .disabled(!store.fromYearEnabled)

                Spacer()
            }
        }
    }
}

private struct StatusLegendItem: View {
    let systemName: String
    let color: Color
    let text: String

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemName)
                .foregroundStyle(color)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

private struct ScanDecisionFilterBar: View {
    @ObservedObject var store: SearchStore
    @ObservedObject var reviewJobs: ReviewJobCoordinator
    @State private var isExportPresented = false
    @State private var isHoveringFilter = false
    @State private var isClearConfirmationPresented = false

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Text("Scan")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    Picker("Scan decision filter", selection: $store.decisionFilter) {
                        ForEach([ScanDecisionFilter.all, .candidate, .use]) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if isHoveringFilter,
                       store.decisionFilter == .use,
                       store.hasMarkedUseWorks {
                        Button("Clear all") {
                            isClearConfirmationPresented = true
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .foregroundStyle(.red)
                        .transition(.opacity)
                    }
                }
                .onHover { isHoveringFilter = $0 }
                .animation(.easeOut(duration: 0.12), value: isHoveringFilter)
            }

            HStack(spacing: 8) {
                Button("Export URLs", systemImage: "square.and.arrow.up") {
                    isExportPresented = true
                }
                .font(.caption)

                Button("Generate Review", systemImage: "doc.badge.gearshape") {
                    if let record = store.currentHistoryRecord {
                        reviewJobs.prepare(record: record)
                    }
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .disabled(store.currentHistoryRecord?.useLedger.papers.isEmpty != false)

                if !reviewJobs.jobs.isEmpty {
                    Menu("Reviews") {
                        ForEach(reviewJobs.jobs.prefix(8)) { job in
                            Button("\(job.query) · v\(job.version)") {
                                reviewJobs.show(job)
                            }
                        }
                    }
                    .font(.caption)
                }
                Spacer()
            }
        }
        .sheet(isPresented: $isExportPresented) {
            UseURLExportSheet(store: store, isPresented: $isExportPresented)
        }
        .confirmationDialog(
            "Clear all Use selections?",
            isPresented: $isClearConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Clear all", role: .destructive) {
                store.clearAllUse()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only affects the current search history.")
        }
    }
}

private struct WorkRow: View {
    let work: Work
    var translatedTitle: String? = nil
    var aiScore: Int? = nil
    var aiReason: String? = nil
    var aiEvidenceLevel: String? = nil
    var decision: ScanDecision = .unreviewed
    var onDecision: (ScanDecision) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                ScanDecisionControl(
                    decision: decision,
                    compact: true,
                    onDecision: onDecision
                )
                if let kind = work.nonPrimaryPublicationKind {
                    Text(kind.label)
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
            }

            Text(translatedTitle ?? work.title)
                .font(.headline)
                .lineLimit(3)

            if translatedTitle != nil {
                Text(work.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text(work.authorsText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let aiScore, let aiReason {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("\(aiScore)%")
                            .font(.caption2.bold().monospacedDigit())
                            .foregroundStyle(aiScore >= 80 ? .green : .orange)
                        if let aiEvidenceLevel {
                            Text(aiEvidenceLevel)
                                .font(.caption2.bold())
                                .foregroundStyle(
                                    aiEvidenceLevel.hasPrefix("全文") ? .blue : .secondary
                                )
                        }
                    }
                    Text(aiReason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 7) {
                Text(work.publicationYear.map(String.init) ?? "年份未知")
                Text(work.venue)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if work.isOpenAccess {
                    Image(systemName: "lock.open")
                        .foregroundStyle(.green)
                        .help("开放获取")
                }
                if work.abstractText != nil {
                    Image(systemName: "text.quote")
                        .foregroundStyle(.blue)
                        .help("有摘要证据")
                }
                if work.hasAvailableFullText {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.purple)
                        .help("可能有全文")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
    }
}

private struct ScanDecisionControl: View {
    let decision: ScanDecision
    var compact = false
    let onDecision: (ScanDecision) -> Void

    @ViewBuilder
    var body: some View {
        if compact {
            if decision == .use {
                Button {
                    onDecision(.unreviewed)
                } label: {
                    Label("Use", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .help("Remove from Use")
            }
        } else {
            Button(decision == .use ? "Undo" : "Use") {
                onDecision(decision == .use ? .unreviewed : .use)
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .font(.caption)
        }
    }
}

private struct DetailPane: View {
    @ObservedObject var store: SearchStore

    var body: some View {
        if let work = store.selectedWork {
            WorkDetail(work: work, store: store)
                .id(work.id)
        } else if !store.works.isEmpty {
            EmptyStateView(
                title: "选择一篇论文",
                systemImage: "doc.text.magnifyingglass"
            )
        } else {
            WelcomeView()
        }
    }
}

private struct WelcomeView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.tint)
            Text("先找证据，再做结论")
                .font(.largeTitle.bold())
            Text("RagBio 不会把模型记忆当作论文事实。它优先读取结构化全文，保留章节、段落与页码；没有全文时才降级到摘要。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 540)
            HStack(spacing: 28) {
                FeatureLabel(icon: "network", title: "实时检索", detail: "OpenAlex")
                FeatureLabel(icon: "doc.text", title: "全文解析", detail: "XML / PDF")
                FeatureLabel(icon: "link", title: "精确引用", detail: "章节 / 页码")
            }
        }
        .padding(48)
    }
}

private struct FeatureLabel: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon)
                .font(.title2)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct WorkDetail: View {
    let work: Work
    @ObservedObject var store: SearchStore
    @State private var selectedTab = 0
    @State private var translationError: String?

    var workEvidence: Evidence? {
        store.evidence.first { $0.work.id == work.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider()
                Picker("", selection: Binding(
                    get: { selectedTab },
                    set: { newTab in
                        let oldValue = selectedTab
                        selectedTab = newTab
                        if oldValue == 0 && selectedTab == 1 {
                            Task { await generateArticleSummary() }
                        }
                    }
                )) {
                    Text("abstract").tag(0)
                    Text("summary").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 460)

                if selectedTab == 0 {
                    abstractContent
                } else {
                    summaryContent
                }
            }
            .padding(30)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) {
            EvidenceFooter(store: store)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if work.isOpenAccess {
                    Label("开放获取", systemImage: "lock.open")
                        .foregroundStyle(.green)
                } else {
                    Label("访问状态未知或受限", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                translationControl
                Text(work.shortID)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Text(displayedTitle)
                .font(.system(size: 28, weight: .bold, design: .serif))
                .textSelection(.enabled)

            if store.isTranslationVisible(for: work.id),
               store.translatedTitles[work.id] != nil {
                Text(work.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let translationError {
                Label(translationError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(work.authorsText)
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Label(work.publicationDate ?? "日期未知", systemImage: "calendar")
                Label(work.venue, systemImage: "building.columns")
                Label("\(work.citedByCount) 次引用", systemImage: "quote.bubble")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                Button("打开论文页面") { store.open(work.landingPageURL) }
                    .disabled(work.landingPageURL == nil)
            }

            ScanDecisionControl(
                decision: store.decision(for: work),
                compact: false
            ) { decision in
                store.setScanDecision(decision, for: work)
            }
        }
    }

    @ViewBuilder
    private var abstractContent: some View {
        if let abstract = work.abstractText {
            VStack(alignment: .leading, spacing: 16) {
                let displayedAbstract = store.isTranslationVisible(for: work.id)
                    ? (store.translatedAbstracts[work.id] ?? abstract)
                    : abstract
                Text(
                    store.isTranslationVisible(for: work.id)
                        && store.translatedAbstracts[work.id] != nil
                        ? "中文摘要"
                        : "abstract"
                )
                    .font(.title3.bold())
                Text(displayedAbstract)
                    .font(.body)
                    .lineSpacing(6)
                    .textSelection(.enabled)

                if store.isTranslationVisible(for: work.id),
                   store.translatedAbstracts[work.id] != nil {
                    Text("英文原文")
                        .font(.title3.bold())
                        .padding(.top, 4)
                    Text(abstract)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
            }
        } else {
            EmptyStateView(
                title: "没有可用摘要",
                systemImage: "text.badge.xmark",
                description: "OpenAlex 只返回了论文元数据。RagBio 不会假装读取过正文；请通过论文页面确认原文。"
            )
        }
    }

    @ViewBuilder
    private var summaryContent: some View {
        let fullTextDocument = store.availableFullTextDocument(for: work)
        let isReadingFullText = store.fullTextState == .loading
            || store.aiVisiblePageFullTextInProgress.contains(work.id)

        VStack(alignment: .leading, spacing: 16) {
            if let note = store.articleSummaries[work.id], let fullTextDocument {
                ArticleSummaryView(
                    note: note,
                    sourceLabel: "Based on full text · \(fullTextDocument.source.title)"
                )
            } else if store.articleSummaryInProgress.contains(work.id) {
                LiteratureReviewSummaryStatusCard(
                    isLoading: true,
                    message: "Generating this paper's AI summary from the full text…"
                )
            } else if let error = store.articleSummaryErrors[work.id] {
                LiteratureReviewSummaryStatusCard(
                    isLoading: false,
                    message: error,
                    onRetry: { Task { await generateArticleSummary() } }
                )
            } else if isReadingFullText {
                LiteratureReviewSummaryStatusCard(
                    isLoading: true,
                    message: "Trying to read accessible full text before generating this paper's summary…"
                )
            } else if fullTextDocument != nil {
                LiteratureReviewSummaryStatusCard(
                    isLoading: true,
                    message: "Preparing this paper's AI summary…"
                )
            } else if case let .failed(message) = store.fullTextState {
                LiteratureReviewSummaryStatusCard(
                    isLoading: false,
                    message: message,
                    onRetry: { Task { await generateArticleSummary() } }
                )
            } else {
                LiteratureReviewSummaryStatusCard(
                    isLoading: false,
                    message: store.aiVisiblePageFullTextFailures[work.id]
                        ?? "No accessible full text was found for this paper, so an AI summary could not be generated.",
                    onRetry: { Task { await generateArticleSummary() } }
                )
            }
        }
    }

    private func generateArticleSummary() async {
        if store.availableFullTextDocument(for: work) == nil {
            await store.loadFullTextForSummary(for: work)
        }
        await store.ensureArticleSummary(for: work)
    }

    private var displayedTitle: String {
        if store.isTranslationVisible(for: work.id),
           let translatedTitle = store.translatedTitles[work.id] {
            return translatedTitle
        }
        return work.title
    }

    @ViewBuilder
    private var translationControl: some View {
        if #available(macOS 15.0, *) {
            WorkTranslationButton(
                work: work,
                store: store,
                errorMessage: $translationError
            )
        } else {
            Button {
                translationError = "系统翻译需要 macOS 15 或更高版本"
            } label: {
                Label("翻译本篇", systemImage: "character.book.closed")
            }
            .help("把当前论文的标题、摘要和已读取段落翻译成中文")
        }
    }
}

@available(macOS 15.0, *)
private struct WorkTranslationButton: View {
    let work: Work
    @ObservedObject var store: SearchStore
    @Binding var errorMessage: String?

    @State private var configuration: TranslationSession.Configuration?
    @State private var isTranslating = false
    @State private var translatedCount = 0
    @State private var translationTotal = 0
    @State private var translationPhase = ""

    private enum Target {
        case title(String)
        case abstract(String)
        case evidence(String)
        case passage(String)
    }

    private var hasMissingTranslations: Bool {
        store.translatedTitles[work.id] == nil
            || (work.abstractText != nil && store.translatedAbstracts[work.id] == nil)
            || (workEvidence != nil && store.translatedEvidence[work.id] == nil)
            || workPassages.contains { store.translatedPassages[$0.key] == nil }
    }

    private var workEvidence: Evidence? {
        store.evidence.first { $0.work.id == work.id }
    }

    private var workPassages: [(key: String, text: String)] {
        var values: [String: String] = [:]
        if let document = store.fullTextDocument,
           document.workID == work.id {
            for paragraph in document.paragraphs {
                let key = store.passageTranslationKey(
                    workID: work.id,
                    passageID: paragraph.id
                )
                values[key] = paragraph.text
            }
        }
        for hit in store.corpusHits where hit.work.id == work.id {
            let key = store.passageTranslationKey(
                workID: work.id,
                passageID: hit.passage.id
            )
            values[key] = hit.passage.paragraph.text
        }
        if store.selectedWork?.id == work.id {
            for hit in store.passageHits {
                let key = store.passageTranslationKey(workID: work.id, passageID: hit.id)
                values[key] = hit.paragraph.text
            }
        }
        return values.map { (key: $0.key, text: $0.value) }
    }

    var body: some View {
        Button {
            if store.isTranslationVisible(for: work.id) && !hasMissingTranslations {
                store.setTranslationVisible(false, for: work.id)
            } else if !hasMissingTranslations {
                store.setTranslationVisible(true, for: work.id)
            } else {
                errorMessage = nil
                isTranslating = true
                let providerConfiguration = AIProviderConfiguration.load(
                    store.activeAIProvider
                )
                if providerConfiguration.isConfigured {
                    translationPhase = "\(providerConfiguration.provider.title) 翻译"
                    Task {
                        await translateWithAI(configuration: providerConfiguration)
                    }
                } else {
                    startSystemTranslation()
                }
            }
        } label: {
            if isTranslating {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(
                        translationTotal > 0
                            ? "\(translationPhase) \(translatedCount)/\(translationTotal)"
                            : "准备翻译"
                    )
                }
            } else {
                Label(
                    store.isTranslationVisible(for: work.id) && !hasMissingTranslations
                        ? "显示英文"
                        : "翻译本篇",
                    systemImage: store.isTranslationVisible(for: work.id) && !hasMissingTranslations
                        ? "character"
                        : "character.book.closed"
                )
            }
        }
        .disabled(isTranslating)
        .help("翻译当前论文的标题、摘要和已读取段落，并缓存结果")
        .translationTask(configuration) { session in
            defer {
                isTranslating = false
                translatedCount = 0
                translationTotal = 0
                translationPhase = ""
            }
            do {
                var priority: [(request: TranslationSession.Request, target: Target)] = []
                var passages: [(request: TranslationSession.Request, target: Target)] = []
                var requestIndex = 0

                func makeItem(
                    _ text: String,
                    target: Target
                ) -> (request: TranslationSession.Request, target: Target)? {
                    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !clean.isEmpty else { return nil }
                    let requestID = "item-\(requestIndex)"
                    requestIndex += 1
                    return (
                        request: TranslationSession.Request(
                            sourceText: clean,
                            clientIdentifier: requestID
                        ),
                        target: target
                    )
                }

                if store.translatedTitles[work.id] == nil,
                   let item = makeItem(work.title, target: .title(work.id)) {
                    priority.append(item)
                }
                if let abstract = work.abstractText,
                   store.translatedAbstracts[work.id] == nil,
                   let item = makeItem(abstract, target: .abstract(work.id)) {
                    priority.append(item)
                }
                if let evidence = workEvidence,
                   store.translatedEvidence[work.id] == nil,
                   let item = makeItem(evidence.sentence, target: .evidence(work.id)) {
                    priority.append(item)
                }
                for passage in workPassages
                where store.translatedPassages[passage.key] == nil {
                    if let item = makeItem(passage.text, target: .passage(passage.key)) {
                        passages.append(item)
                    }
                }

                translationTotal = priority.count + passages.count
                translatedCount = 0

                if !priority.isEmpty {
                    translationPhase = "翻译标题摘要"
                    try await translateBatch(
                        priority,
                        session: session,
                        timeout: .seconds(25)
                    )
                    store.setTranslationVisible(true, for: work.id)
                }

                translationPhase = "翻译正文"
                for batch in makeTranslationBatches(passages) {
                    try Task.checkCancellation()
                    try await translateBatch(
                        batch,
                        session: session,
                        timeout: .seconds(30)
                    )
                }
                store.setTranslationVisible(true, for: work.id)
            } catch is CancellationError {
                errorMessage = "翻译已取消。已经完成的内容仍保留在缓存中。"
            } catch {
                errorMessage = "翻译失败：\(error.localizedDescription)"
            }
        }
        .onDisappear {
            configuration = nil
            isTranslating = false
            translatedCount = 0
            translationTotal = 0
            translationPhase = ""
        }
    }

    private func translateWithAI(
        configuration: AIProviderConfiguration
    ) async {
        do {
            let pending = makeAITranslationItems()
            translationTotal = pending.count
            translatedCount = 0

            let priority = pending.filter {
                switch $0.target {
                case .passage:
                    return false
                default:
                    return true
                }
            }
            let passages = pending.filter {
                if case .passage = $0.target { return true }
                return false
            }

            if !priority.isEmpty {
                translationPhase = "\(configuration.provider.title) 翻译标题摘要"
                try await translateAIBatch(
                    priority,
                    configuration: configuration
                )
                store.setTranslationVisible(true, for: work.id)
            }

            let batches = makeAITranslationBatches(passages)
            if !batches.isEmpty {
                translationPhase = "\(configuration.provider.title) 并行翻译正文"
                try await translateAIBatchesConcurrently(
                    batches,
                    configuration: configuration
                )
            }
            store.setTranslationVisible(true, for: work.id)
            isTranslating = false
            translationPhase = ""
            translatedCount = 0
            translationTotal = 0
        } catch is CancellationError {
            isTranslating = false
            translationPhase = ""
            errorMessage = "翻译已取消。已经完成的内容仍保留在缓存中。"
        } catch {
            errorMessage = "\(configuration.provider.title) 翻译失败，已自动切换系统翻译：\(error.localizedDescription)"
            startSystemTranslation()
        }
    }

    private func translateAIBatch(
        _ batch: [AITranslationTarget],
        configuration: AIProviderConfiguration
    ) async throws {
        let outputs = try await AIQueryPlanner().translateBatch(
            batch.map { AITranslationInput(id: $0.id, text: $0.text) },
            configuration: configuration
        )
        applyAITranslationOutputs(outputs, for: batch)
    }

    private func translateAIBatchesConcurrently(
        _ batches: [[AITranslationTarget]],
        configuration: AIProviderConfiguration
    ) async throws {
        let planner = AIQueryPlanner()
        let maximumConcurrentBatches = 2
        var nextIndex = 0

        try await withThrowingTaskGroup(
            of: (Int, [AITranslationOutput]).self
        ) { group in
            func addBatch(at index: Int) {
                let batch = batches[index]
                group.addTask {
                    let outputs = try await planner.translateBatch(
                        batch.map { AITranslationInput(id: $0.id, text: $0.text) },
                        configuration: configuration
                    )
                    return (index, outputs)
                }
            }

            while nextIndex < min(maximumConcurrentBatches, batches.count) {
                addBatch(at: nextIndex)
                nextIndex += 1
            }

            while let (index, outputs) = try await group.next() {
                applyAITranslationOutputs(outputs, for: batches[index])
                store.setTranslationVisible(true, for: work.id)
                if nextIndex < batches.count {
                    addBatch(at: nextIndex)
                    nextIndex += 1
                }
            }
        }
    }

    private func applyAITranslationOutputs(
        _ outputs: [AITranslationOutput],
        for batch: [AITranslationTarget]
    ) {
        let targets = Dictionary(uniqueKeysWithValues: batch.map { ($0.id, $0.target) })
        for output in outputs {
            guard let target = targets[output.id] else { continue }
            applyTranslation(output.translation, to: target)
            translatedCount += 1
        }
    }

    private struct AITranslationTarget {
        let id: String
        let text: String
        let target: Target
    }

    private func makeAITranslationItems() -> [AITranslationTarget] {
        var items: [AITranslationTarget] = []

        func append(_ text: String, target: Target) {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            items.append(
                AITranslationTarget(
                    id: "item-\(items.count)",
                    text: clean,
                    target: target
                )
            )
        }

        if store.translatedTitles[work.id] == nil {
            append(work.title, target: .title(work.id))
        }
        if let abstract = work.abstractText,
           store.translatedAbstracts[work.id] == nil {
            append(abstract, target: .abstract(work.id))
        }
        if let evidence = workEvidence,
           store.translatedEvidence[work.id] == nil {
            append(evidence.sentence, target: .evidence(work.id))
        }
        for passage in workPassages
        where store.translatedPassages[passage.key] == nil {
            append(passage.text, target: .passage(passage.key))
        }
        return items
    }

    private func makeAITranslationBatches(
        _ items: [AITranslationTarget]
    ) -> [[AITranslationTarget]] {
        let maximumItems = 6
        let maximumCharacters = 8_000
        var batches: [[AITranslationTarget]] = []
        var batch: [AITranslationTarget] = []
        var characters = 0
        for item in items {
            if !batch.isEmpty,
               batch.count >= maximumItems || characters + item.text.count > maximumCharacters {
                batches.append(batch)
                batch = []
                characters = 0
            }
            batch.append(item)
            characters += item.text.count
        }
        if !batch.isEmpty {
            batches.append(batch)
        }
        return batches
    }

    private func applyTranslation(_ text: String, to target: Target) {
        switch target {
        case let .title(workID):
            store.translatedTitles[workID] = text
        case let .abstract(workID):
            store.translatedAbstracts[workID] = text
        case let .evidence(workID):
            store.translatedEvidence[workID] = text
        case let .passage(key):
            store.translatedPassages[key] = text
        }
    }

    private func startSystemTranslation() {
        translationPhase = "系统翻译"
        isTranslating = true
        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: nil,
                target: Locale.Language(identifier: "zh-Hans")
            )
        } else {
            configuration?.invalidate()
        }
    }

    private func translateBatch(
        _ batch: [(request: TranslationSession.Request, target: Target)],
        session: TranslationSession,
        timeout: Duration
    ) async throws {
        let targets = Dictionary(
            uniqueKeysWithValues: batch.compactMap { item in
                item.request.clientIdentifier.map { ($0, item.target) }
            }
        )
        let responses = try await translationsWithTimeout(
            session: session,
            requests: batch.map(\.request),
            timeout: timeout
        )
        for response in responses {
            guard let identifier = response.clientIdentifier,
                  let target = targets[identifier] else { continue }
            applyTranslation(response.targetText, to: target)
            translatedCount += 1
        }
    }

    private func makeTranslationBatches(
        _ items: [(request: TranslationSession.Request, target: Target)]
    ) -> [[(request: TranslationSession.Request, target: Target)]] {
        let maximumItems = 24
        let maximumCharacters = 48_000
        var batches: [[(request: TranslationSession.Request, target: Target)]] = []
        var batch: [(request: TranslationSession.Request, target: Target)] = []
        var characterCount = 0

        for item in items {
            let itemCharacters = item.request.sourceText.count
            if !batch.isEmpty,
               batch.count >= maximumItems
                || characterCount + itemCharacters > maximumCharacters {
                batches.append(batch)
                batch = []
                characterCount = 0
            }
            batch.append(item)
            characterCount += itemCharacters
        }
        if !batch.isEmpty {
            batches.append(batch)
        }
        return batches
    }

    private func translationsWithTimeout(
        session: TranslationSession,
        requests: [TranslationSession.Request],
        timeout: Duration
    ) async throws -> [TranslationSession.Response] {
        try await withThrowingTaskGroup(
            of: [TranslationSession.Response].self
        ) { group in
            group.addTask {
                try await session.translations(from: requests)
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw TranslationBatchError.timeout
            }
            guard let result = try await group.next() else {
                throw TranslationBatchError.noResponse
            }
            group.cancelAll()
            return result
        }
    }
}

private enum TranslationBatchError: LocalizedError {
    case timeout
    case noResponse

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "系统翻译响应超时。请检查网络或系统语言包后重试；已经完成的标题、摘要和正文批次不会丢失。"
        case .noResponse:
            return "系统翻译没有返回结果。"
        }
    }
}

private struct FullTextView: View {
    let work: Work
    @ObservedObject var store: SearchStore
    let showsChineseTranslation: Bool
    let translatedPassages: [String: String]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch store.fullTextState {
            case .idle:
                EmptyStateView(
                    title: "读取并定位全文",
                    systemImage: "doc.text.magnifyingglass",
                    description: sourceDescription
                ) {
                    HStack {
                        Button("自动获取全文") {
                            Task { await store.loadFullText(for: work) }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("导入本地 PDF") {
                            Task { await store.importPDF(for: work) }
                        }
                    }
                }
                .frame(minHeight: 360)
            case .loading:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在获取并解析全文…")
                    Text("依次尝试 Europe PMC、OpenAlex TEI 和开放 PDF")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            case let .failed(message):
                EmptyStateView(
                    title: "全文读取失败",
                    systemImage: "doc.badge.ellipsis",
                    description: message
                ) {
                    HStack {
                        Button("重新尝试") {
                            Task { await store.loadFullText(for: work, forceRefresh: true) }
                        }
                        Button("导入本地 PDF") {
                            Task { await store.importPDF(for: work) }
                        }
                    }
                }
                .frame(minHeight: 360)
            case .loaded:
                if let document = store.fullTextDocument {
                    loadedContent(document)
                }
            }
        }
    }

    private var sourceDescription: String {
        if work.hasAvailableFullText {
            return "优先获取 Europe PMC/OpenAlex 结构化 XML，其次解析开放 PDF。首次全文下载可能需要 OpenAlex API Key。"
        }
        return "数据库未标记可用全文。可以尝试开放来源，或导入你有权访问的 PDF。"
    }

    private func loadedContent(_ document: FullTextDocument) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(document.source.isFullText ? "全文已建立索引" : "当前仅有摘要")
                        .font(.title2.bold())
                    Text(
                        "\(document.source.title) · \(document.sectionCount) 个章节 · "
                            + "\(document.paragraphs.count) 段 · \(document.wordCount.formatted()) 词"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if let value = document.sourceURL, let url = URL(string: value),
                   url.scheme == "http" || url.scheme == "https" {
                    Button("打开全文来源") { store.open(url) }
                }
                Button("重新读取") {
                    Task { await store.loadFullText(for: work, forceRefresh: true) }
                }
            }

            HStack {
                TextField("在全文中定位，例如：off-target detection sensitivity", text: $store.passageQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.searchPassages() }
                Button("定位", systemImage: "scope") {
                    store.searchPassages()
                }
                .buttonStyle(.borderedProminent)
            }

            if store.passageHits.isEmpty {
                EmptyStateView(
                    title: "没有匹配段落",
                    systemImage: "text.magnifyingglass",
                    description: "换用论文中的英文术语，或缩短查询。"
                )
                .frame(minHeight: 220)
            } else {
                Text("最相关的 \(store.passageHits.count) 个段落")
                    .font(.headline)
                ForEach(Array(store.passageHits.enumerated()), id: \.element.id) { index, hit in
                    PassageCard(
                        index: index + 1,
                        hit: hit,
                        translatedText: showsChineseTranslation
                            ? translatedPassages[
                                store.passageTranslationKey(workID: work.id, passageID: hit.id)
                            ]
                            : nil
                    )
                }
            }
        }
    }
}

private struct PassageCard: View {
    let index: Int
    let hit: PassageHit
    var translatedText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("[\(index)]")
                    .font(.headline.monospaced())
                    .foregroundStyle(.tint)
                Text(hit.paragraph.locator)
                    .font(.headline)
                Spacer()
                Text("\(Int(hit.score * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(translatedText ?? hit.paragraph.text)
                .lineSpacing(5)
                .textSelection(.enabled)
            if translatedText != nil {
                Text("英文原文")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text(hit.paragraph.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
            if !hit.matchedTerms.isEmpty {
                Text("命中：\(hit.matchedTerms.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08))
        )
    }
}

private struct FieldSummaryView: View {
    let report: FieldScanReport
    let workTitles: [String: String]
    let workURLs: [String: URL]
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("领域 summary")
                        .font(.title2.bold())
                    Text("基于 \(report.inputSnapshot.rowCount) 篇 · 全文 \(report.inputSnapshot.fullTextSupportedCount) · 仅摘要 \(report.inputSnapshot.abstractOnlyCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !report.fieldOverview.isEmpty {
                        Text(report.fieldOverview)
                            .font(.title3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    compactClaims("要点", Array(report.keyFindings.prefix(5)))
                    compactClaims(
                        "分歧与空白",
                        Array((report.conflictingEvidence + report.researchGaps).prefix(4))
                    )

                    if !report.mustReadPapers.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("必读论文").font(.headline)
                            ForEach(report.mustReadPapers.prefix(6)) { paper in
                                VStack(alignment: .leading, spacing: 2) {
                                    if let url = workURLs[paper.workID] {
                                        Button {
                                            openURL(url)
                                        } label: {
                                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                                Text(paper.title)
                                                    .font(.callout.weight(.medium))
                                                    .multilineTextAlignment(.leading)
                                                Image(systemName: "arrow.up.right.square")
                                                    .font(.caption)
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.tint)
                                    } else {
                                        Text(paper.title).font(.callout.weight(.medium))
                                    }
                                    Text(paper.reason)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                }
                .padding()
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 680, minHeight: 560)
    }

    @ViewBuilder
    private func compactClaims(_ title: String, _ claims: [SupportedClaim]) -> some View {
        if !claims.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                ForEach(claims) { claim in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(claim.text)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(levelLabel(claim.evidenceLevel)) · \(claim.supportingWorkIDs.count) 篇")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func levelLabel(_ level: EvidenceSupportLevel) -> String {
        switch level {
        case .fullTextOnly: return "全文支撑"
        case .mixedFullTextAndAbstract: return "全文+摘要"
        case .abstractOnly: return "仅摘要"
        default: return "仅元数据"
        }
    }
}

private struct ArticleSummaryView: View {
    let note: String
    let sourceLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Article Summary", systemImage: "doc.text.magnifyingglass")
                    .font(.title3.bold())
                Spacer()
                Text(sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 5) {
                ForEach(
                    Array(ArticleSummarySectionOrdering.reviewUseFirst(note).components(separatedBy: "\n").enumerated()),
                    id: \.offset
                ) { _, raw in
                    lineView(raw.trimmingCharacters(in: .whitespaces))
                }
            }
            .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func lineView(_ line: String) -> some View {
        let displayLine = SourceLocatorFormatter.english(line)
        if displayLine.isEmpty {
            Color.clear.frame(height: 3)
        } else if displayLine.lowercased().hasPrefix("screening verdict") {
            Text(displayLine)
                .font(.callout.bold())
                .foregroundStyle(.tint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 4)
        } else if displayLine.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
            Text(displayLine)
                .font(.callout.bold())
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        } else if displayLine.hasPrefix("-") {
            Text(displayLine)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 12)
        } else {
            Text(displayLine)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LiteratureReviewSummaryStatusCard: View {
    let isLoading: Bool
    let message: String
    var onRetry: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if !isLoading, let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(16)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08))
        )
    }
}

private struct EvidenceFooter: View {
    @ObservedObject var store: SearchStore

    var body: some View {
        HStack {
            Label(
                store.fullTextDocument?.source.isFullText == true
                    ? "当前论文已读取全文"
                    : "\(store.abstractCoverage)/\(store.works.count) 篇有摘要证据",
                systemImage: "checkmark.shield"
            )
            Spacer()
            Text("检索：OpenAlex + PubMed · 当前论文：\(store.fullTextDocument?.source.title ?? "摘要")")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct SettingsView: View {
    @StateObject private var reviewProbe = ReviewConnectionProbe()
    @AppStorage(SettingsKeys.contactEmail) private var contactEmail = ""
    @AppStorage(SettingsKeys.grobidEndpoint) private var grobidEndpoint = ""
    @State private var openAlexAPIKey = CredentialStore.string(for: .openAlexAPIKey)
    @State private var semanticScholarAPIKey = CredentialStore.string(
        for: .semanticScholarAPIKey
    )
    @State private var openAlexStatus: SourceValidationState = .idle
    @State private var semanticScholarStatus: SourceValidationState = .idle
    @State private var unpaywallStatus: SourceValidationState = .idle
    @State private var europePMCStatus: SourceValidationState = .idle
    @State private var grobidStatus: SourceValidationState = .idle
    @AppStorage(SettingsKeys.activeAIProvider)
    private var activeAIProviderRaw = AIProvider.deepSeek.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("大模型与 AI 搜索")
                    .font(.title2.bold())
                Text("选择一个启用的厂商。API Key、模型和接口地址会保存在本机配置中。AI 负责理解描述和重排候选，论文结果仍来自 OpenAlex。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(AIProvider.allCases) { provider in
                    AIProviderSettingsCard(
                        provider: provider,
                        activeProviderRaw: $activeAIProviderRaw
                    )
                }

                HStack {
                    Text("清除配置会删除本机保存的 AI API Key、模型和接口地址。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清除全部 AI 配置", role: .destructive) {
                        CredentialStore.removeAllAIKeys()
                        for provider in AIProvider.allCases {
                            UserDefaults.standard.removeObject(
                                forKey: SettingsKeys.aiModel(provider)
                            )
                            UserDefaults.standard.removeObject(
                                forKey: SettingsKeys.aiBaseURL(provider)
                            )
                        }
                        NotificationCenter.default.post(
                            name: .ragBioAIConfigurationCleared,
                            object: nil
                        )
                    }
                }

                ReviewEnginePreviewCard(probe: reviewProbe)

                Divider()
                    .padding(.vertical, 4)

                Text("信息源与访问权限")
                    .font(.title2.bold())
                Text("API Key 保存在本机配置中。测试通过只代表接口凭据有效，不代表每篇付费论文都拥有下载许可。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SourceSettingsCard(
                    title: "OpenAlex",
                    subtitle: "AI 搜索候选、元数据以及 OpenAlex 提供的 TEI/PDF 内容",
                    status: openAlexStatus
                ) {
                    SecureField("OpenAlex API Key", text: $openAlexAPIKey)
                    HStack {
                        Link(
                            "获取免费 API Key",
                            destination: URL(string: "https://openalex.org/settings/api")!
                        )
                        Spacer()
                        ValidationButton(state: openAlexStatus) {
                            openAlexStatus = .testing
                            let result = await CredentialValidator.openAlex(
                                apiKey: openAlexAPIKey
                            )
                            if result.isValid {
                                if let storageError = CredentialStore.saveAndVerify(
                                    openAlexAPIKey,
                                    for: .openAlexAPIKey
                                ) {
                                    openAlexStatus = .invalid(storageError)
                                    return
                                }
                            }
                            openAlexStatus = .result(result)
                        }
                    }
                }

                SourceSettingsCard(
                    title: "Semantic Scholar",
                    subtitle: "补充发现开放 PDF；API Key 可提高请求配额和稳定性",
                    status: semanticScholarStatus
                ) {
                    SecureField("Semantic Scholar API Key", text: $semanticScholarAPIKey)
                    HStack {
                        Link(
                            "申请 API Key",
                            destination: URL(
                                string: "https://www.semanticscholar.org/product/api"
                            )!
                        )
                        Spacer()
                        ValidationButton(state: semanticScholarStatus) {
                            semanticScholarStatus = .testing
                            let result = await CredentialValidator.semanticScholar(
                                apiKey: semanticScholarAPIKey
                            )
                            if result.isValid {
                                if let storageError = CredentialStore.saveAndVerify(
                                    semanticScholarAPIKey,
                                    for: .semanticScholarAPIKey
                                ) {
                                    semanticScholarStatus = .invalid(storageError)
                                    return
                                }
                            }
                            semanticScholarStatus = .result(result)
                        }
                    }
                }

                SourceSettingsCard(
                    title: "Unpaywall",
                    subtitle: "通过 DOI 寻找合法开放版本；不需要账号，只需要联系邮箱",
                    status: unpaywallStatus
                ) {
                    TextField("联系邮箱", text: $contactEmail)
                    HStack {
                        Text("邮箱作为 API 请求参数，不会用来登录出版社。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ValidationButton(state: unpaywallStatus) {
                            unpaywallStatus = .testing
                            let result = await CredentialValidator.unpaywall(
                                email: contactEmail
                            )
                            unpaywallStatus = .result(result)
                        }
                    }
                }

                SourceSettingsCard(
                    title: "Europe PMC",
                    subtitle: "生物医学开放全文 XML；公共 REST API 不需要账户或 API Key",
                    status: europePMCStatus
                ) {
                    HStack {
                        Text("无需填写凭据")
                            .foregroundStyle(.secondary)
                        Spacer()
                        ValidationButton(state: europePMCStatus) {
                            europePMCStatus = .testing
                            europePMCStatus = .result(await CredentialValidator.europePMC())
                        }
                    }
                }

                SourceSettingsCard(
                    title: "本机 GROBID",
                    subtitle: "把 PDF 恢复成章节和段落；通常运行在本机 8070 端口",
                    status: grobidStatus
                ) {
                    TextField("例如：http://localhost:8070", text: $grobidEndpoint)
                    HStack {
                        Text("测试 /api/isalive；失败时仍会回退到 PDFKit 与 OCR。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        ValidationButton(state: grobidStatus) {
                            grobidStatus = .testing
                            grobidStatus = .result(
                                await CredentialValidator.grobid(endpoint: grobidEndpoint)
                            )
                        }
                    }
                }

                SourceSettingsCard(
                    title: "出版社与机构订阅",
                    subtitle: "Elsevier、Springer、Wiley 等没有统一的账号密码接口",
                    status: .informational
                ) {
                    Text("RagBio 不保存出版社密码，也不会绕过登录或付费墙。受限论文请在“打开论文页面”中使用机构登录，下载你有权访问的 PDF 后再导入。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 720, height: 780)
    }
}

private struct ReviewEnginePreviewCard: View {
    @ObservedObject var probe: ReviewConnectionProbe

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(authText, systemImage: authSystemImage)
                    .font(.caption)
                    .foregroundStyle(authColor)

                stateDescription

                HStack {
                    if probe.authMethod == .signedOut {
                        Button("Connect ChatGPT") { probe.connectChatGPT() }
                    }

                    switch probe.state {
                    case .running:
                        Button("Pause") { probe.pause() }
                    case .paused:
                        Button("Resume") { probe.resume() }
                        Button("Cancel", role: .destructive) { probe.cancel() }
                    case let .completed(artifacts):
                        Button("Open Excel") { probe.openWorkbook() }
                            .disabled(!FileManager.default.fileExists(
                                atPath: artifacts.workbookURL.path
                            ))
                        Button("Open Word") { probe.openManuscript() }
                            .disabled(!FileManager.default.fileExists(
                                atPath: artifacts.manuscriptURL.path
                            ))
                        Button("Show in Finder") { probe.showInFinder() }
                        Button("Run Live Codex Probe") { probe.startLive() }
                            .disabled(probe.authMethod != .chatgpt)
                    default:
                        Button("Run Fixture Probe") { probe.startFixture() }
                        Button("Run Live Codex Probe") { probe.startLive() }
                            .disabled(probe.authMethod != .chatgpt)
                    }

                    Spacer()
                    Button("Refresh Sign-in") { probe.refreshAuthStatus() }
                        .buttonStyle(.borderless)
                }
            }
            .padding(4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Engine Preview").font(.headline)
                Text("Connection test only — this does not generate a systematic review.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { probe.refreshAuthStatus() }
    }

    @ViewBuilder
    private var stateDescription: some View {
        switch probe.state {
        case .idle:
            Text("Ready to test the local Review Engine connection.")
                .foregroundStyle(.secondary)
        case let .running(stage, detail):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(stage.capitalized).font(.caption.bold())
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
        case let .paused(threadID):
            Label("Paused · Thread \(threadID)", systemImage: "pause.circle")
                .font(.caption)
        case let .blocked(category, message):
            Label("\(category.rawValue.capitalized): \(message)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case let .connected(threadID):
            Label("Live Codex connection completed · Thread \(threadID)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .completed:
            Label("Connection test completed. Both files are ready.", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private var authText: String {
        switch probe.authMethod {
        case .chatgpt: "ChatGPT connected"
        case .apiKey: "API key login detected — subscription probe disabled"
        case .signedOut: "ChatGPT not connected"
        }
    }

    private var authSystemImage: String {
        probe.authMethod == .chatgpt ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark"
    }

    private var authColor: Color {
        probe.authMethod == .chatgpt ? .green : .secondary
    }
}

private struct AIProviderSettingsCard: View {
    let provider: AIProvider
    @Binding var activeProviderRaw: String

    @State private var apiKey: String
    @State private var model: String
    @State private var baseURL: String
    @State private var status: SourceValidationState = .idle

    init(provider: AIProvider, activeProviderRaw: Binding<String>) {
        self.provider = provider
        _activeProviderRaw = activeProviderRaw
        let configuration = AIProviderConfiguration.load(provider)
        _apiKey = State(initialValue: configuration.apiKey)
        _model = State(initialValue: configuration.model)
        _baseURL = State(initialValue: configuration.baseURL)
    }

    var body: some View {
        SourceSettingsCard(
            title: provider.title,
            subtitle: activeProviderRaw == provider.rawValue
                ? "当前用于 AI 搜索"
                : "配置后可切换为 AI 搜索引擎",
            status: status
        ) {
            SecureField("API Key", text: $apiKey)

            HStack {
                TextField("模型名称", text: $model)
                Menu("推荐模型") {
                    ForEach(provider.recommendedModels, id: \.self) { recommended in
                        Button(recommended) {
                            model = recommended
                        }
                    }
                }
            }

            TextField("API 接口地址", text: $baseURL)

            HStack {
                Link("查看官方模型与 API 文档", destination: provider.documentationURL)
                Spacer()
                if activeProviderRaw == provider.rawValue {
                    Label("已启用", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button("设为 AI 搜索") {
                        persistNonSecretSettings()
                        activeProviderRaw = provider.rawValue
                    }
                }
                Button("删除凭据", role: .destructive) {
                    CredentialStore.set("", for: provider.credentialKey)
                    apiKey = ""
                    status = .idle
                }
                ValidationButton(state: status) {
                    status = .testing
                    let configuration = AIProviderConfiguration(
                        provider: provider,
                        apiKey: apiKey,
                        model: model,
                        baseURL: baseURL
                    )
                    let result = await AIQueryPlanner().validate(
                        configuration: configuration
                    )
                    if result.isValid {
                        if let storageError = CredentialStore.saveAndVerify(
                            apiKey,
                            for: provider.credentialKey
                        ) {
                            status = .invalid(storageError)
                            return
                        }
                        persistNonSecretSettings()
                        activeProviderRaw = provider.rawValue
                    }
                    status = .result(result)
                }
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .ragBioAIConfigurationCleared)
        ) { _ in
            apiKey = ""
            model = provider.defaultModel
            baseURL = provider.defaultBaseURL
            status = .idle
        }
    }

    private func persistNonSecretSettings() {
        UserDefaults.standard.set(model, forKey: SettingsKeys.aiModel(provider))
        UserDefaults.standard.set(baseURL, forKey: SettingsKeys.aiBaseURL(provider))
    }
}

private enum SourceValidationState {
    case idle
    case testing
    case valid(String)
    case invalid(String)
    case informational

    static func result(_ result: CredentialValidationResult) -> Self {
        result.isValid ? .valid(result.message) : .invalid(result.message)
    }
}

private struct SourceSettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let status: SourceValidationState
    @ViewBuilder let content: () -> Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                content()
                validationMessage
            }
            .padding(4)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                validationIcon
            }
        }
    }

    @ViewBuilder
    private var validationIcon: some View {
        switch status {
        case .valid:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .invalid:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .testing:
            ProgressView().controlSize(.small)
        case .idle, .informational:
            EmptyView()
        }
    }

    @ViewBuilder
    private var validationMessage: some View {
        switch status {
        case let .valid(message):
            Label(message, systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case let .invalid(message):
            Label(message, systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        case .idle, .testing, .informational:
            EmptyView()
        }
    }
}

private struct ValidationButton: View {
    let state: SourceValidationState
    let action: () async -> Void

    var body: some View {
        Button("保存并测试") {
            Task { await action() }
        }
        .disabled(isTesting)
    }

    private var isTesting: Bool {
        if case .testing = state { return true }
        return false
    }
}

private struct EmptyStateView<Actions: View>: View {
    let title: String
    let systemImage: String
    var description: String?
    @ViewBuilder var actions: () -> Actions

    init(
        title: String,
        systemImage: String,
        description: String? = nil,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
            if let description {
                Text(description)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 360)
            }
            actions()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension EmptyStateView where Actions == EmptyView {
    init(title: String, systemImage: String, description: String? = nil) {
        self.init(
            title: title,
            systemImage: systemImage,
            description: description,
            actions: { EmptyView() }
        )
    }
}
