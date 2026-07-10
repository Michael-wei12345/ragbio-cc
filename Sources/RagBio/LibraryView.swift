import SwiftUI

struct LibraryView: View {
    @ObservedObject var store: LibraryStore
    @State private var isDropTargeted = false
    @State private var showsURLImport = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 300, ideal: 360)
        } detail: {
            detail
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await store.importPDFs(urls) }
            return urls.contains { $0.pathExtension.lowercased() == "pdf" }
        } isTargeted: {
            isDropTargeted = $0
        }
        .sheet(isPresented: $showsURLImport) {
            ImportURLSheet(store: store)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, dash: [10]))
                    .padding(14)
                    .overlay {
                        Label("松开以加入 PDF 文库", systemImage: "square.and.arrow.down")
                            .font(.title2.bold())
                            .padding(20)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
            }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("我的文库")
                            .font(.title2.bold())
                        Text("\(store.items.count) 篇论文与收藏")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("选择多个 PDF…", systemImage: "doc.badge.plus") {
                            Task { await store.choosePDFs() }
                        }
                        Button("导入文件夹…", systemImage: "folder.badge.plus") {
                            Task { await store.choosePDFFolder() }
                        }
                        Button("从 Zotero 导入…", systemImage: "books.vertical") {
                            Task { await store.choosePDFFolder(suggestZotero: true) }
                        }
                        Divider()
                        Button("导入 URL…", systemImage: "link.badge.plus") {
                            store.clearError()
                            showsURLImport = true
                        }
                        Button("导出文库 URL…", systemImage: "square.and.arrow.up") {
                            store.exportURLs()
                        }
                        .disabled(store.exportableURLCount == 0)
                    } label: {
                        Label("导入", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack {
                    TextField("跨文库检索具体段落", text: $store.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.search() }
                    Button("检索", systemImage: "magnifyingglass") {
                        store.search()
                    }
                    .disabled(
                        store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                if case let .importing(completed, total) = store.importState {
                    HStack {
                        ProgressView(value: Double(completed), total: Double(total))
                        Text("正在导入 \(completed)/\(total)")
                            .font(.caption)
                    }
                }
                if let error = store.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                }
            }
            .padding(16)

            Divider()

            if store.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 36, weight: .light))
                    Text("拖入 PDF 或点击导入")
                        .font(.headline)
                    Text("文件与索引只保存在这台 Mac。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(
                    store.items,
                    selection: Binding(
                        get: { store.selection },
                        set: { newValue in
                            Task { await store.select(newValue) }
                        }
                    )
                ) { item in
                    LibraryItemRow(item: item)
                        .tag(item.id)
                }
                .listStyle(.sidebar)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if !store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            LibrarySearchResults(store: store)
        } else if let item = store.selectedItem {
            LibraryDocumentDetail(item: item, store: store)
                .id(item.id)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 50, weight: .light))
                    .foregroundStyle(.tint)
                Text("建立你的本地论文库")
                    .font(.largeTitle.bold())
                Text("支持批量导入、拖放、跨文档检索和精确页码引用。")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ImportURLSheet: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var titleText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("导入文章 URL")
                    .font(.title2.bold())
                Text("只保存 URL 引用，不下载 PDF，也不影响已有文库索引。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("文章 URL，例如 https://doi.org/...", text: $urlText)
                .textFieldStyle(.roundedBorder)
            TextField("标题，可选", text: $titleText)
                .textFieldStyle(.roundedBorder)

            if let error = store.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("导入") {
                    let url = urlText
                    let title = titleText
                    Task {
                        await store.importURL(url, title: title)
                        if store.errorMessage == nil {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

private struct LibraryItemRow: View {
    let item: LibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.headline)
                .lineLimit(3)
            if item.isOnlineFavorite {
                Label("在线收藏 · \(favoriteTime)", systemImage: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if item.isURLReference {
                Label("URL 导入 · \(favoriteTime)", systemImage: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let sourceURL = item.sourceURL {
                    Text(sourceURL)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Text("\(item.pageCount) 页 · \(item.paragraphCount) 段")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !item.tags.isEmpty {
                Text(item.tags.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
    }

    private var favoriteTime: String {
        item.addedAt.formatted(
            .dateTime
                .year()
                .month(.twoDigits)
                .day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
        )
    }
}

private struct LibraryDocumentDetail: View {
    let item: LibraryItem
    @ObservedObject var store: LibraryStore
    @State private var title: String
    @State private var tags: String
    @State private var showDeleteConfirmation = false

    init(item: LibraryItem, store: LibraryStore) {
        self.item = item
        self.store = store
        _title = State(initialValue: item.title)
        _tags = State(initialValue: item.tags.joined(separator: ", "))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 28, weight: .bold, design: .serif))
                        Text(item.opensSourceURL ? item.libraryKindTitle : item.originalFileName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(
                        item.opensSourceURL ? "打开 URL" : "打开 PDF",
                        systemImage: item.opensSourceURL ? "safari" : "doc"
                    ) {
                        if item.opensSourceURL {
                            store.openSelectedSource()
                        } else {
                            Task { await store.openSelectedPDF() }
                        }
                    }
                    .disabled(item.opensSourceURL && item.sourceURL == nil)
                    Menu {
                        if item.isPDFBacked {
                            Button("重新建立索引") {
                                Task { await store.reindexSelected() }
                            }
                            Divider()
                        }
                        Button("从文库删除", role: .destructive) {
                            showDeleteConfirmation = true
                        }
                    } label: {
                        Label("管理", systemImage: "ellipsis.circle")
                    }
                }

                HStack(spacing: 18) {
                    if item.opensSourceURL {
                        Label(item.libraryKindTitle, systemImage: item.isOnlineFavorite ? "bookmark.fill" : "link")
                        if let year = item.publicationYear {
                            Label(String(year), systemImage: "calendar")
                        }
                        if let venue = item.venue {
                            Label(venue, systemImage: "building.columns")
                        }
                    } else {
                        Label("\(item.pageCount) 页", systemImage: "doc")
                    }
                    if item.isPDFBacked || item.paragraphCount > 0 {
                        Label("\(item.paragraphCount) 段", systemImage: "text.alignleft")
                        Label("\(item.wordCount.formatted()) 词", systemImage: "character.cursor.ibeam")
                    }
                    Label(
                        (item.opensSourceURL ? "保存于 " : "导入于 ")
                            + item.addedAt.formatted(
                                .dateTime
                                    .year()
                                    .month(.twoDigits)
                                    .day(.twoDigits)
                                    .hour(.twoDigits(amPM: .omitted))
                                    .minute(.twoDigits)
                            ),
                        systemImage: "clock"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                GroupBox("文档信息") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("标题", text: $title)
                        TextField("标签，用逗号分隔", text: $tags)
                        HStack {
                            Spacer()
                            Button("保存") {
                                Task { await store.updateTitle(title, tags: tags) }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(8)
                }

                if let document = store.selectedDocument {
                    Text("索引预览")
                        .font(.title2.bold())
                    ForEach(document.paragraphs.prefix(8)) { paragraph in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(paragraph.locator)
                                .font(.headline)
                            Text(paragraph.text)
                                .lineLimit(5)
                                .textSelection(.enabled)
                        }
                        .padding(14)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                } else if item.isURLReference, let sourceURL = item.sourceURL {
                    GroupBox("URL") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(sourceURL)
                                .textSelection(.enabled)
                                .foregroundStyle(.secondary)
                            Button("打开 URL", systemImage: "safari") {
                                store.openSelectedSource()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 920, alignment: .leading)
        }
        .confirmationDialog(
            "确定从文库删除这篇论文？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(deleteTitle, role: .destructive) {
                Task { await store.deleteSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(
                item.isOnlineFavorite
                    ? "只会删除 RagBio 中保存的收藏和证据副本。"
                    : item.isURLReference
                        ? "只会删除 RagBio 中保存的 URL 引用。"
                        : "只会删除 RagBio 文库中的副本，不影响最初导入位置的文件。"
            )
        }
    }

    private var deleteTitle: String {
        if item.isOnlineFavorite { return "删除收藏" }
        if item.isURLReference { return "删除 URL 引用" }
        return "删除 PDF 和本地索引"
    }
}

private struct LibrarySearchResults: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("文库检索")
                            .font(.largeTitle.bold())
                        Text(
                            "在 \(store.items.count) 篇文库论文中找到 "
                                + "\(store.hits.count) 个相关段落"
                        )
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("复制报告", systemImage: "doc.on.doc") {
                        store.copyReport()
                    }
                    .disabled(store.hits.isEmpty)
                    Button("导出 Markdown", systemImage: "square.and.arrow.up") {
                        store.exportReport()
                    }
                    .disabled(store.hits.isEmpty)
                    Button("清除检索") {
                        store.query = ""
                        store.search()
                    }
                }

                if store.hits.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 40, weight: .light))
                        Text("没有找到相关段落")
                            .font(.title3.bold())
                        Text("尝试使用论文中的英文术语或更短的查询。")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 360)
                } else {
                    ForEach(Array(store.hits.enumerated()), id: \.element.id) { index, hit in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text("[\(index + 1)]")
                                    .font(.headline.monospaced())
                                    .foregroundStyle(.tint)
                                Text(hit.item.title)
                                    .font(.headline)
                                Spacer()
                                Text("\(Int(hit.passage.score * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(hit.passage.paragraph.text)
                                .lineSpacing(5)
                                .textSelection(.enabled)
                            Text(hit.passage.paragraph.locator)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(16)
                        .background(
                            Color(nsColor: .controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                    }
                }
            }
            .padding(30)
            .frame(maxWidth: 940, alignment: .leading)
        }
    }
}
