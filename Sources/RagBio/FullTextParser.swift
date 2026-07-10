import AppKit
import Foundation
import PDFKit
import Vision

final class StructuredXMLParser: NSObject, XMLParserDelegate {
    private var paragraphs: [FullTextParagraph] = []
    private var currentSection = "正文"
    private var currentText = ""
    private var captureKind: CaptureKind?
    private var insideBody = false
    private var sectionDepth = 0
    private var currentPage: Int?

    private enum CaptureKind {
        case heading
        case paragraph
    }

    func parse(
        data: Data,
        workID: String,
        title: String,
        source: FullTextSource,
        sourceURL: String?
    ) throws -> FullTextDocument {
        paragraphs = []
        currentSection = "正文"
        currentText = ""
        captureKind = nil
        insideBody = false
        sectionDepth = 0
        currentPage = nil

        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            throw parser.parserError ?? FullTextError.emptyDocument
        }
        guard !paragraphs.isEmpty else {
            throw FullTextError.emptyDocument
        }

        return FullTextDocument(
            workID: workID,
            title: title,
            source: source,
            sourceURL: sourceURL,
            paragraphs: paragraphs,
            loadedAt: Date()
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = normalizedName(elementName, qualifiedName: qName)
        if name == "body" {
            insideBody = true
        } else if insideBody && (name == "div" || name == "sec") {
            sectionDepth += 1
        } else if insideBody && (name == "head" || name == "title") && sectionDepth > 0 {
            captureKind = .heading
            currentText = ""
        } else if insideBody && name == "p" {
            captureKind = .paragraph
            currentText = ""
        } else if insideBody && name == "pb" {
            currentPage = Int(attributeDict["n"] ?? "")
        }
    }

    func parser(
        _ parser: XMLParser,
        foundCharacters string: String
    ) {
        guard captureKind != nil else { return }
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalizedName(elementName, qualifiedName: qName)
        if insideBody && (name == "head" || name == "title"), captureKind == .heading {
            let heading = clean(currentText)
            if !heading.isEmpty {
                currentSection = heading
            }
            captureKind = nil
            currentText = ""
        } else if insideBody && name == "p", captureKind == .paragraph {
            appendParagraph(clean(currentText))
            captureKind = nil
            currentText = ""
        } else if insideBody && (name == "div" || name == "sec") {
            sectionDepth = max(0, sectionDepth - 1)
        } else if name == "body" {
            insideBody = false
        }
    }

    private func appendParagraph(_ text: String) {
        guard text.count >= 30 else { return }
        let ordinal = paragraphs.count + 1
        paragraphs.append(
            FullTextParagraph(
                id: "p-\(ordinal)",
                section: currentSection,
                text: text,
                ordinal: ordinal,
                page: currentPage
            )
        )
    }

    private func clean(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedName(_ elementName: String, qualifiedName: String?) -> String {
        let value = elementName.isEmpty ? (qualifiedName ?? "") : elementName
        return value.split(separator: ":").last.map(String.init)?.lowercased() ?? value.lowercased()
    }
}

enum PDFTextParser {
    private struct PageText {
        let number: Int
        let lines: [String]
    }

    static func parse(
        url: URL,
        workID: String,
        title: String,
        source: FullTextSource,
        sourceURL: String?
    ) throws -> FullTextDocument {
        guard let pdf = PDFDocument(url: url) else {
            throw FullTextError.invalidPDF
        }

        var pages: [PageText] = []
        for pageIndex in 0..<pdf.pageCount {
            guard let page = pdf.page(at: pageIndex) else { continue }
            let extracted = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let text = extracted.count >= 30
                ? extracted
                : (OCRTextExtractor.recognize(page: page) ?? extracted)
            guard !text.isEmpty else { continue }
            pages.append(
                PageText(
                    number: pageIndex + 1,
                    lines: text.components(separatedBy: .newlines)
                )
            )
        }

        let repeatedLines = repeatedShortLines(in: pages.map(\.lines))
        var reachedReferences = false
        var paragraphs: [FullTextParagraph] = []
        for page in pages {
            let blocks = cleanedBlocks(
                from: page.lines,
                repeatedLines: repeatedLines,
                reachedReferences: &reachedReferences
            )
                .flatMap { block -> [String] in
                    if block.count > 1200 {
                        return chunk(block, maximumLength: 1000)
                    }
                    return [block]
                }
                .filter { $0.count >= 40 }

            for block in blocks {
                let ordinal = paragraphs.count + 1
                paragraphs.append(
                    FullTextParagraph(
                        id: "p-\(ordinal)",
                        section: "PDF 正文",
                        text: block,
                        ordinal: ordinal,
                        page: page.number
                    )
                )
            }
            if reachedReferences { break }
        }

        guard !paragraphs.isEmpty else {
            throw FullTextError.invalidPDF
        }
        return FullTextDocument(
            workID: workID,
            title: title,
            source: source,
            sourceURL: sourceURL,
            paragraphs: paragraphs,
            loadedAt: Date()
        )
    }

    private static func cleanedBlocks(
        from lines: [String],
        repeatedLines: Set<String>,
        reachedReferences: inout Bool
    ) -> [String] {
        var blocks: [String] = []
        var currentLines: [String] = []

        func flush() {
            let text = normalize(join(currentLines))
            if text.count >= 40 {
                blocks.append(text)
            }
            currentLines = []
        }

        for rawLine in lines {
            let line = normalizeLine(rawLine)
            guard !line.isEmpty else {
                flush()
                continue
            }
            if isReferenceHeading(line) {
                flush()
                reachedReferences = true
                break
            }
            let canonical = canonicalLine(line)
            guard !repeatedLines.contains(canonical),
                  !isBoilerplateLine(line) else {
                continue
            }
            currentLines.append(line)
        }

        flush()
        return blocks
    }

    private static func repeatedShortLines(in pages: [[String]]) -> Set<String> {
        guard pages.count >= 3 else { return [] }
        var pageCounts: [String: Int] = [:]
        for page in pages {
            let uniqueLines = Set(
                page
                    .map(normalizeLine)
                    .filter { !$0.isEmpty && $0.count <= 140 }
                    .map(canonicalLine)
                    .filter { !$0.isEmpty }
            )
            for line in uniqueLines {
                pageCounts[line, default: 0] += 1
            }
        }
        let threshold = max(3, Int(ceil(Double(pages.count) * 0.25)))
        return Set(pageCounts.compactMap { line, count in
            count >= threshold ? line : nil
        })
    }

    private static func join(_ lines: [String]) -> String {
        var output = ""
        for line in lines {
            guard !line.isEmpty else { continue }
            if output.hasSuffix("-") {
                output.removeLast()
                output += line
            } else {
                if !output.isEmpty { output += " " }
                output += line
            }
        }
        return output
    }

    private static func normalizeLine(_ line: String) -> String {
        line
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalLine(_ line: String) -> String {
        normalizeLine(line)
            .lowercased()
            .replacingOccurrences(of: #"^\W+|\W+$"#, with: "", options: .regularExpression)
    }

    private static func isBoilerplateLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        if line.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil {
            return true
        }
        if lower.range(of: #"^page\s+\d+(\s+of\s+\d+)?$"#, options: .regularExpression) != nil {
            return true
        }
        if lower.hasPrefix("doi:")
            || lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("www.") {
            return true
        }
        if lower.contains("downloaded from")
            || lower.contains("all rights reserved")
            || lower.contains("published by")
            || lower.contains("copyright ©")
            || lower.contains("© ") {
            return true
        }
        return false
    }

    private static func isReferenceHeading(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.range(
            of: #"^(references|bibliography|literature cited|works cited|参考文献)\s*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func normalize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "-\n", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func chunk(_ text: String, maximumLength: Int) -> [String] {
        var chunks: [String] = []
        var remaining = text[...]
        while remaining.count > maximumLength {
            let end = remaining.index(remaining.startIndex, offsetBy: maximumLength)
            let candidate = remaining[..<end]
            let split = candidate.lastIndex(where: { ".!?。！？".contains($0) }) ?? end
            chunks.append(String(remaining[..<split]).trimmingCharacters(in: .whitespaces))
            remaining = remaining[split...].drop(while: \.isWhitespace)
        }
        if !remaining.isEmpty {
            chunks.append(String(remaining))
        }
        return chunks
    }
}

private enum OCRTextExtractor {
    static func recognize(page: PDFPage) -> String? {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let targetWidth: CGFloat = 1800
        let targetHeight = targetWidth * bounds.height / bounds.width
        let image = page.thumbnail(
            of: CGSize(width: targetWidth, height: targetHeight),
            for: .mediaBox
        )
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant"]

        do {
            try VNImageRequestHandler(cgImage: cgImage).perform([request])
            let observations = (request.results ?? []).sorted { lhs, rhs in
                let verticalDifference = lhs.boundingBox.midY - rhs.boundingBox.midY
                if abs(verticalDifference) > 0.02 {
                    return lhs.boundingBox.midY > rhs.boundingBox.midY
                }
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            let text = observations.compactMap {
                $0.topCandidates(1).first?.string
            }.joined(separator: "\n")
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
