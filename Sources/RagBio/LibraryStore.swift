import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [LibraryItem] = []
    @Published var selection: LibraryItem.ID?
    @Published var query = ""
    @Published private(set) var hits: [LibraryPassageHit] = []
    @Published private(set) var importState: LibraryImportState = .idle
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedDocument: FullTextDocument?

    private let service: LibraryService

    init(service: LibraryService = LibraryService()) {
        self.service = service
        Task {
            await reload()
            search()
        }
    }

    var selectedItem: LibraryItem? {
        items.first { $0.id == selection }
    }

    func clearError() {
        errorMessage = nil
    }

    var exportableURLCount: Int {
        Set(items.compactMap { item in
            item.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }).count
    }

    func contains(workID: String) -> Bool {
        items.contains { $0.sourceWorkID == workID }
    }

    func favoriteDate(workID: String) -> Date? {
        items.first { $0.sourceWorkID == workID }?.addedAt
    }

    func addFavorite(work: Work, document: FullTextDocument?) async {
        errorMessage = nil
        do {
            let item = try await service.addFavorite(work: work, document: document)
            items = await service.loadItems()
            selection = item.id
        } catch {
            errorMessage = "收藏失败：\(error.localizedDescription)"
        }
    }

    func reload() async {
        items = await service.loadItems()
        if selection == nil {
            selection = items.first?.id
        }
        await loadSelection()
    }

    func choosePDFs() async {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "选择一个或多个 PDF。文件与索引会复制到 RagBio 本地文库。"
        guard panel.runModal() == .OK else { return }
        await importPDFs(panel.urls)
    }

    func choosePDFFolder(suggestZotero: Bool = false) async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = suggestZotero
            ? "选择 Zotero 的 storage 文件夹，RagBio 会递归导入其中的 PDF。"
            : "选择文件夹，RagBio 会递归导入其中的 PDF。"

        if suggestZotero {
            let zotero = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Zotero", isDirectory: true)
                .appendingPathComponent("storage", isDirectory: true)
            if FileManager.default.fileExists(atPath: zotero.path) {
                panel.directoryURL = zotero
            }
        }

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            errorMessage = "无法读取所选文件夹。"
            return
        }
        let urls = enumerator.compactMap { $0 as? URL }.filter {
            $0.pathExtension.lowercased() == "pdf"
        }
        if urls.isEmpty {
            errorMessage = "所选文件夹中没有找到 PDF。"
            return
        }
        await importPDFs(urls)
    }

    func importPDFs(_ urls: [URL]) async {
        let pdfURLs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        guard !pdfURLs.isEmpty else {
            errorMessage = "请选择 PDF 文件。"
            return
        }
        importState = .importing(completed: 0, total: pdfURLs.count)
        errorMessage = nil

        var importedIDs: [UUID] = []
        for (index, url) in pdfURLs.enumerated() {
            do {
                let imported = try await service.importPDFs([url])
                importedIDs.append(contentsOf: imported.map(\.id))
            } catch {
                errorMessage = "\(url.lastPathComponent)：\(error.localizedDescription)"
            }
            importState = .importing(completed: index + 1, total: pdfURLs.count)
        }

        importState = .idle
        items = await service.loadItems()
        if let first = importedIDs.first {
            selection = first
        }
        await loadSelection()
        search()
    }

    func importURL(_ rawURL: String, title: String?) async {
        errorMessage = nil
        guard let url = normalizedURL(from: rawURL) else {
            errorMessage = "请输入有效的文章 URL。"
            return
        }

        do {
            let item = try await service.addURLReference(url: url, title: title)
            items = await service.loadItems()
            selection = item.id
            await loadSelection()
            search()
        } catch {
            errorMessage = "导入 URL 失败：\(error.localizedDescription)"
        }
    }

    func select(_ id: LibraryItem.ID?) async {
        selection = id
        await loadSelection()
    }

    func loadSelection() async {
        guard let selection else {
            selectedDocument = nil
            return
        }
        selectedDocument = await service.loadDocument(itemID: selection)
    }

    func search() {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuery.isEmpty else {
            hits = []
            return
        }

        Task {
            var collected: [LibraryPassageHit] = []
            for item in items {
                guard let document = await service.loadDocument(itemID: item.id) else { continue }
                let itemHits = HybridRetriever.search(
                    query: cleanQuery,
                    paragraphs: document.paragraphs,
                    limit: 5
                ).map { LibraryPassageHit(item: item, passage: $0) }
                collected.append(contentsOf: itemHits)
            }
            guard query.trimmingCharacters(in: .whitespacesAndNewlines) == cleanQuery else {
                return
            }
            hits = collected
                .sorted { $0.passage.score > $1.passage.score }
                .prefix(40)
                .map { $0 }
        }
    }

    func updateTitle(_ title: String, tags: String) async {
        guard var item = selectedItem else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        item.title = cleanTitle
        item.tags = tags
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        item.modifiedAt = Date()
        do {
            try await service.update(item)
            await reload()
            selection = item.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reindexSelected() async {
        guard let item = selectedItem, item.isPDFBacked else { return }
        importState = .importing(completed: 0, total: 1)
        do {
            _ = try await service.reindex(item)
            await reload()
            selection = item.id
            search()
        } catch {
            errorMessage = error.localizedDescription
        }
        importState = .idle
    }

    func deleteSelected() async {
        guard let item = selectedItem else { return }
        do {
            try await service.delete(item)
            selection = nil
            await reload()
            search()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openSelectedPDF() async {
        guard let item = selectedItem, item.isPDFBacked else { return }
        let url = await service.fileURL(for: item)
        NSWorkspace.shared.open(url)
    }

    func openSelectedSource() {
        guard let value = selectedItem?.sourceURL, let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyReport() {
        guard let report = reportText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func exportReport() {
        guard let report = reportText() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "RagBio-本地文库报告.md"
        panel.message = "导出带 PDF 页码和段落位置的 Markdown 报告"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportURLs() {
        let urls = items
            .compactMap { $0.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .uniqued()
        guard !urls.isEmpty else {
            errorMessage = "当前文库没有可导出的 URL。"
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "RagBio-library-urls.txt"
        panel.message = "导出当前文库中保存的 URL；不会导出 PDF 或其他文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try urls.joined(separator: "\n")
                .appending("\n")
                .write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "导出 URL 失败：\(error.localizedDescription)"
        }
    }

    private func reportText() -> String? {
        guard !hits.isEmpty else { return nil }
        let body = hits.enumerated().map { index, hit in
            "## [\(index + 1)] \(hit.item.title)\n\n"
                + "> \(hit.passage.paragraph.text)\n\n"
                + "- 定位：\(hit.passage.paragraph.locator)\n"
                + (
                    hit.item.isOnlineFavorite
                        ? "- 来源：在线收藏\n- 链接：\(hit.item.sourceURL ?? "未知")"
                        : "- 本地文件：\(hit.item.originalFileName)"
                )
        }.joined(separator: "\n\n")
        return "# RagBio 本地文库证据报告\n\n"
            + "**检索主题：** \(query)\n\n"
            + "**方法：** 在 \(items.count) 篇文库论文的本地段落索引中进行混合检索。以下均为保存的原文或摘要，不包含模型补写。\n\n"
            + body
    }

    private func normalizedURL(from rawValue: String) -> URL? {
        let clean = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        let candidates: [String]
        if clean.contains("://") {
            candidates = [clean]
        } else {
            candidates = ["https://\(clean)"]
        }

        return candidates
            .compactMap(URL.init(string:))
            .first { url in
                guard let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme),
                      url.host != nil else {
                    return false
                }
                return true
            }
    }
}
