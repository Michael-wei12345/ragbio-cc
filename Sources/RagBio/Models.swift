import Foundation

struct OpenAlexResponse: Decodable {
    let meta: Meta
    let results: [Work]

    struct Meta: Decodable {
        let count: Int
    }
}

struct Work: Codable, Identifiable, Hashable {
    let id: String
    let doi: String?
    let title: String
    let publicationDate: String?
    let publicationYear: Int?
    let citedByCount: Int
    let authorships: [Authorship]
    let abstractInvertedIndex: [String: [Int]]?
    let primaryLocation: Location?
    let bestOpenAccessLocation: Location?
    let openAccess: OpenAccess?
    let contentURLs: ContentURLs?
    let hasFullText: Bool?
    let ids: WorkIDs?
    let locations: [Location]
    let isRetracted: Bool?
    let type: String?
    var publicationTypes: [String]? = nil
    let language: String?
    let abstractPlain: String?

    enum CodingKeys: String, CodingKey {
        case id, doi, title, authorships, ids, locations, type, publicationTypes, language
        case publicationDate = "publication_date"
        case publicationYear = "publication_year"
        case citedByCount = "cited_by_count"
        case abstractInvertedIndex = "abstract_inverted_index"
        case primaryLocation = "primary_location"
        case bestOpenAccessLocation = "best_oa_location"
        case openAccess = "open_access"
        case contentURLs = "content_urls"
        case hasFullText = "has_fulltext"
        case isRetracted = "is_retracted"
        case abstractPlain = "abstract_plain"
    }

    var shortID: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    var authorsText: String {
        let names = authorships.compactMap(\.author.displayName)
        guard !names.isEmpty else { return "作者未知" }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(3).joined(separator: ", ") + " 等"
    }

    var venue: String {
        primaryLocation?.source?.displayName ?? "来源未知"
    }

    var abstractText: String? {
        if let abstractPlain {
            let trimmed = abstractPlain.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        guard let index = abstractInvertedIndex, !index.isEmpty else { return nil }
        let maxPosition = index.values.flatMap { $0 }.max() ?? -1
        guard maxPosition >= 0 else { return nil }

        var words = Array(repeating: "", count: maxPosition + 1)
        for (word, positions) in index {
            for position in positions where words.indices.contains(position) {
                words[position] = word
            }
        }
        let text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    var landingPageURL: URL? {
        let candidates = [
            bestOpenAccessLocation?.landingPageURL,
            primaryLocation?.landingPageURL,
            doi,
            id
        ]
        return candidates.compactMap { $0 }.compactMap(URL.init(string:)).first
    }

    var pdfURL: URL? {
        [bestOpenAccessLocation?.pdfURL, primaryLocation?.pdfURL]
            .compactMap { $0 }
            .compactMap(URL.init(string:))
            .first
    }

    var isOpenAccess: Bool {
        openAccess?.isOpenAccess == true
            || bestOpenAccessLocation?.isOpenAccess == true
            || primaryLocation?.isOpenAccess == true
    }

    var hasAvailableFullText: Bool {
        hasFullText == true
            || contentURLs?.grobidXML != nil
            || contentURLs?.pdf != nil
            || pdfURL != nil
    }

    var normalizedDOI: String? {
        guard let doi else { return nil }
        let normalized = doi
            .lowercased()
            .replacingOccurrences(
                of: #"^(https?://(dx\.)?doi\.org/|doi:\s*)"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    var normalizedPMID: String? {
        ids?.pmid?
            .replacingOccurrences(of: "https://pubmed.ncbi.nlm.nih.gov/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var normalizedPMCID: String? {
        ids?.pmcid?
            .replacingOccurrences(of: "https://www.ncbi.nlm.nih.gov/pmc/articles/", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    var nonPrimaryPublicationKind: NonPrimaryPublicationKind? {
        if isRetracted == true { return .retracted }

        let values = Set(([type] + (publicationTypes ?? []).map(Optional.some))
            .compactMap { $0 }
            .map(Self.normalizedPublicationType))

        let primaryTypes: Set<String> = [
            "adaptive clinical trial", "case reports", "clinical study", "clinical trial",
            "clinical trial phase i", "clinical trial phase ii", "clinical trial phase iii",
            "clinical trial phase iv", "comparative study", "controlled clinical trial",
            "evaluation study", "multicenter study", "observational study",
            "randomized controlled trial", "validation study"
        ]
        if !values.isDisjoint(with: primaryTypes) { return nil }

        if values.contains("meta analysis") { return .metaAnalysis }
        if values.contains("systematic review") || values.contains("review") { return .review }
        if values.contains("guideline") || values.contains("practice guideline") {
            return .guideline
        }
        if values.contains("consensus statement") { return .consensus }
        if values.contains("clinical trial protocol") || values.contains("protocol") {
            return .studyProtocol
        }
        if values.contains("editorial") { return .editorial }
        if values.contains("comment") { return .comment }
        if values.contains("letter") { return .letter }
        return nil
    }

    private static func normalizedPublicationType(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum NonPrimaryPublicationKind: String, Hashable {
    case review
    case metaAnalysis
    case guideline
    case consensus
    case editorial
    case comment
    case letter
    case studyProtocol
    case retracted

    var label: String {
        switch self {
        case .review: return "Review"
        case .metaAnalysis: return "Meta-analysis"
        case .guideline: return "Guideline"
        case .consensus: return "Consensus"
        case .editorial: return "Editorial"
        case .comment: return "Comment"
        case .letter: return "Letter"
        case .studyProtocol: return "Protocol"
        case .retracted: return "Retracted"
        }
    }
}

struct WorkIDs: Codable, Hashable {
    let pmid: String?
    let pmcid: String?
}

struct ContentURLs: Codable, Hashable {
    let pdf: String?
    let grobidXML: String?

    enum CodingKeys: String, CodingKey {
        case pdf
        case grobidXML = "grobid_xml"
    }
}

struct Authorship: Codable, Hashable {
    let author: Author
}

struct Author: Codable, Hashable {
    let id: String?
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct Location: Codable, Hashable {
    let isOpenAccess: Bool?
    let landingPageURL: String?
    let pdfURL: String?
    let source: Source?
    let license: String?
    let version: String?

    enum CodingKeys: String, CodingKey {
        case source, license, version
        case isOpenAccess = "is_oa"
        case landingPageURL = "landing_page_url"
        case pdfURL = "pdf_url"
    }
}

struct Source: Codable, Hashable {
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
    }
}

struct OpenAccess: Codable, Hashable {
    let isOpenAccess: Bool?
    let status: String?
    let openAccessURL: String?

    enum CodingKeys: String, CodingKey {
        case status
        case isOpenAccess = "is_oa"
        case openAccessURL = "oa_url"
    }
}

struct Evidence: Identifiable, Hashable {
    let id = UUID()
    let work: Work
    let sentence: String
    let score: Int
    let citationNumber: Int
}

enum FullTextSource: String, Codable, Hashable {
    case europePMC
    case openAlexTEI
    case openAlexPDF
    case unpaywallPDF
    case publisherPDF
    case localGROBID
    case importedPDF
    case abstract

    var title: String {
        switch self {
        case .europePMC: return "Europe PMC XML"
        case .openAlexTEI: return "OpenAlex TEI XML"
        case .openAlexPDF: return "OpenAlex PDF"
        case .unpaywallPDF: return "Unpaywall 开放版本"
        case .publisherPDF: return "开放 PDF"
        case .localGROBID: return "本机 GROBID"
        case .importedPDF: return "本地 PDF"
        case .abstract: return "摘要"
        }
    }

    var isFullText: Bool {
        self != .abstract
    }
}

struct FullTextParagraph: Identifiable, Codable, Hashable {
    let id: String
    let section: String
    let text: String
    let ordinal: Int
    let page: Int?

    var locator: String {
        var parts = [SourceLocatorFormatter.englishSection(section), "Paragraph \(ordinal)"]
        if let page {
            parts.append("Page \(page)")
        }
        return parts.joined(separator: " · ")
    }
}

enum SourceLocatorFormatter {
    static func englishSection(_ section: String) -> String {
        switch section {
        case "PDF 正文": return "PDF full text"
        case "正文": return "Full text"
        case "摘要": return "Abstract"
        default: return section
        }
    }

    static func english(_ text: String) -> String {
        var value = text
            .replacingOccurrences(of: "PDF 正文", with: "PDF full text")
            .replacingOccurrences(of: "正文", with: "Full text")
            .replacingOccurrences(of: "摘要", with: "Abstract")
        value = value.replacingOccurrences(
            of: #"第\s*(\d+)\s*段"#,
            with: "Paragraph $1",
            options: .regularExpression
        )
        return value.replacingOccurrences(
            of: #"第\s*(\d+)\s*页"#,
            with: "Page $1",
            options: .regularExpression
        )
    }
}

struct LiteratureReviewSourceExcerpt: Identifiable, Codable, Hashable {
    let id: String
    let paragraphID: String
    let label: String
    let locator: String
    let text: String
}

struct FullTextDocument: Codable, Hashable {
    let workID: String
    let title: String
    let source: FullTextSource
    let sourceURL: String?
    let paragraphs: [FullTextParagraph]
    let loadedAt: Date

    var wordCount: Int {
        paragraphs.reduce(0) {
            $0 + $1.text.split(whereSeparator: \.isWhitespace).count
        }
    }

    var sectionCount: Int {
        Set(paragraphs.map(\.section)).count
    }
}

struct PassageHit: Identifiable, Hashable {
    let id: String
    let paragraph: FullTextParagraph
    let score: Double
    let matchedTerms: [String]
}

struct CorpusPassageHit: Identifiable, Hashable {
    let work: Work
    let document: FullTextDocument
    let passage: PassageHit

    var id: String {
        "\(work.id)-\(passage.id)"
    }
}

enum CorpusAnalysisState: Equatable {
    case idle
    case loading(completed: Int, total: Int)
    case loaded
    case failed(String)
}

enum FullTextLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum FullTextError: LocalizedError {
    case noUsableSource
    case apiKeyRequired
    case invalidPDF
    case emptyDocument
    case network(String)

    var errorDescription: String? {
        switch self {
        case .noUsableSource:
            return "没有找到可合法读取的结构化全文或开放 PDF。你可以导入自己有权访问的 PDF。"
        case .apiKeyRequired:
            return "OpenAlex 全文需要免费 API Key。请在设置中填写，或导入本地 PDF。"
        case .invalidPDF:
            return "PDF 无法解析，可能是损坏文件或纯扫描图像。"
        case .emptyDocument:
            return "全文已取得，但没有解析出可检索的正文段落。"
        case let .network(message):
            return message
        }
    }
}

enum SearchSort: String, CaseIterable, Identifiable, Codable {
    case relevance
    case newest
    case cited

    var id: Self { self }

    var title: String {
        switch self {
        case .relevance: return "相关性"
        case .newest: return "最新发表"
        case .cited: return "引用最多"
        }
    }

    var apiValue: String? {
        switch self {
        case .relevance: return nil
        case .newest: return "publication_date:desc"
        case .cited: return "cited_by_count:desc"
        }
    }
}

enum SearchError: LocalizedError {
    case invalidURL
    case invalidResponse
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无法创建 OpenAlex 请求。"
        case .invalidResponse:
            return "OpenAlex 返回了无法识别的响应。"
        case let .api(status, message):
            return "OpenAlex 请求失败（\(status)）：\(message)"
        }
    }
}
