import Foundation

/// Searches PubMed (NCBI E-utilities) and maps results into the app's `Work` model.
///
/// PubMed is used as a second discovery source alongside OpenAlex. ESearch returns
/// relevance-ranked PMIDs; EFetch returns the full records (including abstracts) as XML,
/// which we parse and map into `Work`. PubMed's automatic term mapping expands plain
/// keywords into MeSH-aware queries, so callers can pass natural search text.
struct PubMedClient {
    var session: URLSession = .shared

    private let esearchBase = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi"
    private let efetchBase = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/efetch.fcgi"
    private let userAgent = "RagBio/0.1 (macOS academic search client)"

    enum PubMedError: LocalizedError {
        case invalidURL
        case badStatus(Int)
        case parseFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "无法构建 PubMed 请求。"
            case let .badStatus(code): return "PubMed 请求失败（\(code)）。"
            case .parseFailed: return "PubMed 返回的记录无法解析。"
            }
        }
    }

    func search(
        query: String,
        fromYear: Int?,
        maxResults: Int,
        contactEmail: String?,
        timeout: TimeInterval = 15
    ) async throws -> [Work] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }

        let pmids = try await esearch(
            term: term,
            maxResults: maxResults,
            fromYear: fromYear,
            contactEmail: contactEmail,
            timeout: timeout
        )
        guard !pmids.isEmpty else { return [] }

        let articles = try await efetch(
            pmids: pmids,
            contactEmail: contactEmail,
            timeout: timeout
        )
        return articles.map(makeWork(from:))
    }

    // MARK: - ESearch

    private struct ESearchResponse: Decodable {
        struct Result: Decodable { let idlist: [String] }
        let esearchresult: Result
    }

    private func esearch(
        term: String,
        maxResults: Int,
        fromYear: Int?,
        contactEmail: String?,
        timeout: TimeInterval
    ) async throws -> [String] {
        var components = URLComponents(string: esearchBase)
        var items = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "retmax", value: String(max(1, maxResults))),
            URLQueryItem(name: "retmode", value: "json"),
            URLQueryItem(name: "sort", value: "relevance"),
            URLQueryItem(name: "tool", value: "RagBio")
        ]
        if let fromYear {
            let currentYear = Calendar.current.component(.year, from: Date())
            items.append(URLQueryItem(name: "mindate", value: String(fromYear)))
            items.append(URLQueryItem(name: "maxdate", value: String(max(fromYear, currentYear))))
            items.append(URLQueryItem(name: "datetype", value: "pdat"))
        }
        if let contactEmail, contactEmail.contains("@") {
            items.append(URLQueryItem(name: "email", value: contactEmail))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw PubMedError.invalidURL }

        let data = try await get(url, timeout: timeout)
        let decoded = try JSONDecoder().decode(ESearchResponse.self, from: data)
        return decoded.esearchresult.idlist
    }

    // MARK: - EFetch

    private func efetch(
        pmids: [String],
        contactEmail: String?,
        timeout: TimeInterval
    ) async throws -> [PubMedArticle] {
        var components = URLComponents(string: efetchBase)
        var items = [
            URLQueryItem(name: "db", value: "pubmed"),
            URLQueryItem(name: "id", value: pmids.joined(separator: ",")),
            URLQueryItem(name: "retmode", value: "xml"),
            URLQueryItem(name: "tool", value: "RagBio")
        ]
        if let contactEmail, contactEmail.contains("@") {
            items.append(URLQueryItem(name: "email", value: contactEmail))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw PubMedError.invalidURL }

        let data = try await get(url, timeout: timeout)
        let parser = XMLParser(data: data)
        let delegate = PubMedEFetchParser()
        parser.delegate = delegate
        guard parser.parse() else { throw PubMedError.parseFailed }
        return delegate.articles
    }

    private func get(_ url: URL, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw PubMedError.badStatus(-1) }
        guard (200..<300).contains(http.statusCode) else { throw PubMedError.badStatus(http.statusCode) }
        return data
    }

    // MARK: - Mapping

    private func makeWork(from article: PubMedArticle) -> Work {
        let year = Int(article.year) ?? PubMedClient.firstYear(in: article.medlineDate)
        let publicationDate = year.map { String(format: "%04d-01-01", $0) }

        let normalizedDOI = article.doi.map { raw -> String in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.lowercased().hasPrefix("http") { return trimmed }
            return "https://doi.org/\(trimmed)"
        }

        let landing = "https://pubmed.ncbi.nlm.nih.gov/\(article.pmid)/"
        let source = article.journal.isEmpty ? nil : Source(displayName: article.journal)
        let primary = Location(
            isOpenAccess: nil,
            landingPageURL: landing,
            pdfURL: nil,
            source: source,
            license: nil,
            version: nil
        )
        let authorships = article.authors.map { Authorship(author: Author(id: nil, displayName: $0)) }
        let pmcid = article.pmcid.map { $0.uppercased().hasPrefix("PMC") ? $0 : "PMC\($0)" }
        let abstract = article.abstractParts.isEmpty
            ? nil
            : article.abstractParts.joined(separator: "\n\n")

        return Work(
            id: "https://pubmed.ncbi.nlm.nih.gov/\(article.pmid)",
            doi: normalizedDOI,
            title: article.title.isEmpty ? "(无标题)" : article.title,
            publicationDate: publicationDate,
            publicationYear: year,
            citedByCount: 0,
            authorships: authorships,
            abstractInvertedIndex: nil,
            primaryLocation: primary,
            bestOpenAccessLocation: nil,
            openAccess: nil,
            contentURLs: nil,
            hasFullText: nil,
            ids: WorkIDs(pmid: article.pmid, pmcid: pmcid),
            locations: [primary],
            isRetracted: article.isRetracted ? true : nil,
            type: nil,
            language: article.language,
            abstractPlain: abstract
        )
    }

    private static func firstYear(in text: String) -> Int? {
        guard let match = text.range(of: #"\d{4}"#, options: .regularExpression) else { return nil }
        return Int(text[match])
    }
}

// MARK: - EFetch XML parsing

private struct PubMedArticle {
    var pmid = ""
    var title = ""
    var abstractParts: [String] = []
    var journal = ""
    var year = ""
    var medlineDate = ""
    var authors: [String] = []
    var doi: String?
    var pmcid: String?
    var language: String?
    var isRetracted = false
}

private final class PubMedEFetchParser: NSObject, XMLParserDelegate {
    private(set) var articles: [PubMedArticle] = []

    private var current: PubMedArticle?
    private var buffer = ""

    private var inJournal = false
    private var inPubDate = false
    private var inAuthor = false
    private var inAbstract = false
    private var authorLast = ""
    private var authorFore = ""
    private var abstractLabel: String?
    private var articleIdType: String?
    private var elocationType: String?

    private let clearOnStart: Set<String> = [
        "ArticleTitle", "AbstractText", "PMID", "LastName", "ForeName",
        "Initials", "CollectiveName", "Year", "MedlineDate", "Title",
        "Language", "PublicationType", "ArticleId", "ELocationID"
    ]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if clearOnStart.contains(elementName) { buffer = "" }

        switch elementName {
        case "PubmedArticle":
            current = PubMedArticle()
        case "Journal":
            inJournal = true
        case "PubDate":
            inPubDate = true
        case "Author":
            inAuthor = true
            authorLast = ""
            authorFore = ""
        case "Abstract", "OtherAbstract":
            inAbstract = true
        case "AbstractText":
            abstractLabel = attributeDict["Label"]
        case "ArticleId":
            articleIdType = attributeDict["IdType"]?.lowercased()
        case "ELocationID":
            elocationType = attributeDict["EIdType"]?.lowercased()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "PMID":
            if current?.pmid.isEmpty == true, !text.isEmpty {
                current?.pmid = text
            }
        case "ArticleTitle":
            if current?.title.isEmpty == true { current?.title = text }
        case "AbstractText":
            if inAbstract, !text.isEmpty {
                if let label = abstractLabel, !label.isEmpty {
                    current?.abstractParts.append("\(label.uppercased()): \(text)")
                } else {
                    current?.abstractParts.append(text)
                }
            }
            abstractLabel = nil
        case "Abstract", "OtherAbstract":
            inAbstract = false
        case "Title":
            if inJournal, current?.journal.isEmpty == true { current?.journal = text }
        case "Year":
            if inPubDate, current?.year.isEmpty == true { current?.year = text }
        case "MedlineDate":
            if inPubDate, current?.medlineDate.isEmpty == true { current?.medlineDate = text }
        case "PubDate":
            inPubDate = false
        case "Journal":
            inJournal = false
        case "LastName":
            if inAuthor { authorLast = text }
        case "ForeName":
            if inAuthor { authorFore = text }
        case "Initials":
            if inAuthor, authorFore.isEmpty { authorFore = text }
        case "CollectiveName":
            if inAuthor, !text.isEmpty { current?.authors.append(text) }
        case "Author":
            inAuthor = false
            let name = [authorFore, authorLast]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !name.isEmpty { current?.authors.append(name) }
        case "Language":
            if current?.language == nil, !text.isEmpty { current?.language = text }
        case "PublicationType":
            if text.caseInsensitiveCompare("Retracted Publication") == .orderedSame {
                current?.isRetracted = true
            }
        case "ArticleId":
            if articleIdType == "doi", current?.doi == nil, !text.isEmpty {
                current?.doi = text
            } else if articleIdType == "pmc", current?.pmcid == nil, !text.isEmpty {
                current?.pmcid = text
            }
            articleIdType = nil
        case "ELocationID":
            if elocationType == "doi", current?.doi == nil, !text.isEmpty {
                current?.doi = text
            }
            elocationType = nil
        case "PubmedArticle":
            if let article = current, !article.pmid.isEmpty { articles.append(article) }
            current = nil
        default:
            break
        }

        buffer = ""
    }
}
