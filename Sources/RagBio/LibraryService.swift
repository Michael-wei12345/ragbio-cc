import CryptoKit
import Foundation
import PDFKit

actor LibraryService {
    private let root: URL
    private let filesDirectory: URL
    private let documentsDirectory: URL
    private let catalogURL: URL

    init(root customRoot: URL? = nil) {
        if let customRoot {
            root = customRoot
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            root = applicationSupport
                .appendingPathComponent("RagBio", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        }
        filesDirectory = root.appendingPathComponent("Files", isDirectory: true)
        documentsDirectory = root.appendingPathComponent("Documents", isDirectory: true)
        catalogURL = root.appendingPathComponent("catalog.json")

        try? FileManager.default.createDirectory(
            at: filesDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(
            at: documentsDirectory,
            withIntermediateDirectories: true
        )
    }

    func loadItems() -> [LibraryItem] {
        guard let data = try? Data(contentsOf: catalogURL),
              let items = try? JSONDecoder().decode([LibraryItem].self, from: data) else {
            return []
        }
        return items.sorted { $0.addedAt > $1.addedAt }
    }

    func importPDFs(_ urls: [URL]) async throws -> [LibraryItem] {
        var items = loadItems()
        var imported: [LibraryItem] = []

        for sourceURL in urls {
            let accessGranted = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessGranted {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let fileData = try Data(contentsOf: sourceURL)
            let contentHash = SHA256.hash(data: fileData)
                .map { String(format: "%02x", $0) }
                .joined()
            if let existing = items.first(where: { $0.contentHash == contentHash }) {
                imported.append(existing)
                continue
            }

            let id = UUID()
            let storedFileName = "\(id.uuidString).pdf"
            let destination = filesDirectory.appendingPathComponent(storedFileName)
            try fileData.write(to: destination, options: .atomic)

            do {
                let title = PDFMetadata.title(from: destination)
                    ?? sourceURL.deletingPathExtension().lastPathComponent
                let document = try await parseLibraryPDF(
                    data: fileData,
                    url: destination,
                    workID: "library:\(id.uuidString)",
                    title: title
                )
                guard let pdf = PDFDocument(url: destination) else {
                    throw FullTextError.invalidPDF
                }

                let item = LibraryItem(
                    id: id,
                    title: title,
                    originalFileName: sourceURL.lastPathComponent,
                    storedFileName: storedFileName,
                    contentHash: contentHash,
                    addedAt: Date(),
                    modifiedAt: Date(),
                    tags: [],
                    pageCount: pdf.pageCount,
                    wordCount: document.wordCount,
                    paragraphCount: document.paragraphs.count,
                    sourceWorkID: nil,
                    sourceURL: nil,
                    authors: nil,
                    venue: nil,
                    publicationYear: nil
                )
                try saveDocument(document, itemID: id)
                items.append(item)
                imported.append(item)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw error
            }
        }

        try saveCatalog(items)
        return imported
    }

    func loadDocument(itemID: UUID) -> FullTextDocument? {
        let url = documentsDirectory
            .appendingPathComponent(itemID.uuidString)
            .appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FullTextDocument.self, from: data)
    }

    func update(_ updated: LibraryItem) throws {
        var items = loadItems()
        guard let index = items.firstIndex(where: { $0.id == updated.id }) else { return }
        items[index] = updated
        try saveCatalog(items)
    }

    func reindex(_ item: LibraryItem) async throws -> LibraryItem {
        let fileURL = filesDirectory.appendingPathComponent(item.storedFileName)
        let data = try Data(contentsOf: fileURL)
        let document = try await parseLibraryPDF(
            data: data,
            url: fileURL,
            workID: "library:\(item.id.uuidString)",
            title: item.title
        )
        guard let pdf = PDFDocument(url: fileURL) else {
            throw FullTextError.invalidPDF
        }
        var updated = item
        updated.modifiedAt = Date()
        updated = LibraryItem(
            id: updated.id,
            title: updated.title,
            originalFileName: updated.originalFileName,
            storedFileName: updated.storedFileName,
            contentHash: updated.contentHash,
            addedAt: updated.addedAt,
            modifiedAt: updated.modifiedAt,
            tags: updated.tags,
            pageCount: pdf.pageCount,
            wordCount: document.wordCount,
            paragraphCount: document.paragraphs.count,
            sourceWorkID: updated.sourceWorkID,
            sourceURL: updated.sourceURL,
            authors: updated.authors,
            venue: updated.venue,
            publicationYear: updated.publicationYear
        )
        try saveDocument(document, itemID: item.id)
        try update(updated)
        return updated
    }

    func delete(_ item: LibraryItem) throws {
        var items = loadItems()
        items.removeAll { $0.id == item.id }
        try saveCatalog(items)
        if item.isPDFBacked {
            try? FileManager.default.removeItem(
                at: filesDirectory.appendingPathComponent(item.storedFileName)
            )
        }
        try? FileManager.default.removeItem(
            at: documentsDirectory
                .appendingPathComponent(item.id.uuidString)
                .appendingPathExtension("json")
        )
    }

    func addFavorite(work: Work, document: FullTextDocument?) throws -> LibraryItem {
        var items = loadItems()
        if let existing = items.first(where: { $0.sourceWorkID == work.id }) {
            return existing
        }

        let id = UUID()
        let storedDocument = document ?? abstractDocument(for: work)
        let item = LibraryItem(
            id: id,
            title: work.title,
            originalFileName: "在线收藏",
            storedFileName: "",
            contentHash: nil,
            addedAt: Date(),
            modifiedAt: Date(),
            tags: [],
            pageCount: 0,
            wordCount: storedDocument?.wordCount ?? 0,
            paragraphCount: storedDocument?.paragraphs.count ?? 0,
            sourceWorkID: work.id,
            sourceURL: work.landingPageURL?.absoluteString,
            authors: work.authorsText,
            venue: work.venue,
            publicationYear: work.publicationYear
        )
        if let storedDocument {
            try saveDocument(storedDocument, itemID: id)
        }
        items.append(item)
        try saveCatalog(items)
        return item
    }

    func addURLReference(url: URL, title: String?) throws -> LibraryItem {
        var items = loadItems()
        let cleanURL = url.absoluteString
        if let existing = items.first(where: { $0.sourceURL == cleanURL }) {
            return existing
        }

        let id = UUID()
        let cleanTitle = title?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let item = LibraryItem(
            id: id,
            title: cleanTitle?.isEmpty == false ? cleanTitle! : defaultTitle(for: url),
            originalFileName: "URL 导入",
            storedFileName: "",
            contentHash: nil,
            addedAt: Date(),
            modifiedAt: Date(),
            tags: [],
            pageCount: 0,
            wordCount: 0,
            paragraphCount: 0,
            sourceWorkID: nil,
            sourceURL: cleanURL,
            authors: nil,
            venue: nil,
            publicationYear: nil
        )
        items.append(item)
        try saveCatalog(items)
        return item
    }

    func fileURL(for item: LibraryItem) -> URL {
        filesDirectory.appendingPathComponent(item.storedFileName)
    }

    private func defaultTitle(for url: URL) -> String {
        let host = url.host ?? ""
        let pathComponent = url.deletingPathExtension().lastPathComponent
        if !pathComponent.isEmpty, pathComponent != "/" {
            return host.isEmpty ? pathComponent : "\(host) · \(pathComponent)"
        }
        return host.isEmpty ? url.absoluteString : host
    }

    private func abstractDocument(for work: Work) -> FullTextDocument? {
        guard let abstract = work.abstractText else { return nil }
        return FullTextDocument(
            workID: work.id,
            title: work.title,
            source: .abstract,
            sourceURL: work.landingPageURL?.absoluteString,
            paragraphs: [
                FullTextParagraph(
                    id: "abstract-1",
                    section: "摘要",
                    text: abstract,
                    ordinal: 1,
                    page: nil
                )
            ],
            loadedAt: Date()
        )
    }

    private func saveDocument(_ document: FullTextDocument, itemID: UUID) throws {
        let data = try JSONEncoder().encode(document)
        let url = documentsDirectory
            .appendingPathComponent(itemID.uuidString)
            .appendingPathExtension("json")
        try data.write(to: url, options: .atomic)
    }

    private func parseLibraryPDF(
        data: Data,
        url: URL,
        workID: String,
        title: String
    ) async throws -> FullTextDocument {
        if let endpoint = UserDefaults.standard.string(forKey: SettingsKeys.grobidEndpoint),
           !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let document = try? await GROBIDClient.parse(
               pdfData: data,
               workID: workID,
               title: title,
               sourceURL: url.path,
               endpoint: endpoint
           ) {
            return document
        }
        return try PDFTextParser.parse(
            url: url,
            workID: workID,
            title: title,
            source: .importedPDF,
            sourceURL: url.path
        )
    }

    private func saveCatalog(_ items: [LibraryItem]) throws {
        let data = try JSONEncoder().encode(items)
        try data.write(to: catalogURL, options: .atomic)
    }
}

private enum PDFMetadata {
    static func title(from url: URL) -> String? {
        guard let document = PDFDocument(url: url),
              let attributes = document.documentAttributes,
              let value = attributes[PDFDocumentAttribute.titleAttribute] as? String else {
            return nil
        }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
