import Foundation

struct SearchHistoryExportDocument: Equatable {
    var text: String
    var urlCount: Int
    var skippedPaperCount: Int

    static let empty = SearchHistoryExportDocument(
        text: "",
        urlCount: 0,
        skippedPaperCount: 0
    )
}

enum SearchHistoryURLResolver {
    static func url(for work: Work) -> URL? {
        if let doi = work.normalizedDOI?.lowercased(),
           doi.range(of: #"^10\.\d{4,9}/\S+$"#, options: .regularExpression) != nil,
           let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let url = normalizedHTTPURL("https://doi.org/\(encodedDOI)") {
            return url
        }
        if let pmid = work.normalizedPMID,
           hasOnlyASCIIDigits(pmid),
           let url = normalizedHTTPURL("https://pubmed.ncbi.nlm.nih.gov/\(pmid)/") {
            return url
        }
        for value in [
            work.bestOpenAccessLocation?.landingPageURL,
            work.primaryLocation?.landingPageURL
        ].compactMap({ $0 }) {
            guard let url = normalizedHTTPURL(value),
                  !isDirectPDF(url),
                  !isIdentifierHost(url.host, domain: "doi.org"),
                  !isIdentifierHost(url.host, domain: "openalex.org") else { continue }
            return url
        }
        guard let shortID = openAlexID(work.id) else { return nil }
        return normalizedHTTPURL("https://openalex.org/\(shortID)")
    }

    private static func normalizedHTTPURL(_ value: String) -> URL? {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil else { return nil }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        guard let path = uppercasePercentEscapes(components.percentEncodedPath) else { return nil }
        components.percentEncodedPath = path
        if let query = components.percentEncodedQuery {
            guard let normalizedQuery = uppercasePercentEscapes(query) else { return nil }
            components.percentEncodedQuery = normalizedQuery
        }
        return components.url
    }

    private static func uppercasePercentEscapes(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        var result: [UInt8] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 37 else {
                result.append(bytes[index])
                index += 1
                continue
            }
            guard index + 2 < bytes.count,
                  let first = uppercaseHex(bytes[index + 1]),
                  let second = uppercaseHex(bytes[index + 2]) else { return nil }
            result.append(contentsOf: [37, first, second])
            index += 3
        }
        return String(bytes: result, encoding: .utf8)
    }

    private static func uppercaseHex(_ value: UInt8) -> UInt8? {
        if (48...57).contains(value) || (65...70).contains(value) { return value }
        if (97...102).contains(value) { return value - 32 }
        return nil
    }

    private static func hasOnlyASCIIDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func openAlexID(_ value: String) -> String? {
        let candidate: String
        if let components = URLComponents(string: value), components.scheme != nil {
            guard let scheme = components.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  isIdentifierHost(components.host, domain: "openalex.org") else { return nil }
            let path = components.path.split(separator: "/").map(String.init)
            guard path.count == 1
                    || (path.count == 2 && path[0].lowercased() == "works") else { return nil }
            candidate = path.last ?? ""
        } else {
            guard !value.contains("/") else { return nil }
            candidate = value
        }
        let uppercased = candidate.uppercased()
        guard uppercased.hasPrefix("W"),
              hasOnlyASCIIDigits(String(uppercased.dropFirst())) else { return nil }
        return uppercased
    }

    private static func isIdentifierHost(_ host: String?, domain: String) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == domain || host.hasSuffix(".\(domain)")
    }

    private static func isDirectPDF(_ url: URL) -> Bool {
        let filename = url.lastPathComponent.split(separator: ";", maxSplits: 1).first ?? ""
        return filename.lowercased().hasSuffix(".pdf")
    }
}

enum SearchHistoryExportBuilder {
    static func make(
        records: [SearchHistoryRecord],
        timeZone: TimeZone = .current
    ) -> SearchHistoryExportDocument {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var lines: [String] = []
        var urlCount = 0
        var skippedPaperCount = 0
        let eligible = records.filter { !$0.useLedger.papers.isEmpty }
            .sorted {
                if $0.lastSuccessfulSearchAt != $1.lastSuccessfulSearchAt {
                    return $0.lastSuccessfulSearchAt < $1.lastSuccessfulSearchAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }

        for record in eligible {
            var seen = Set<String>()
            var urls: [String] = []
            for paper in record.useLedger.papers {
                guard let value = SearchHistoryURLResolver.url(for: paper.work)?.absoluteString else {
                    skippedPaperCount += 1
                    continue
                }
                if seen.insert(value).inserted {
                    urls.append(value)
                }
            }
            lines.append("------")
            lines.append("Query: \(record.displayQuery)")
            lines.append("Search Time: \(formatter.string(from: record.lastSuccessfulSearchAt))")
            lines.append(contentsOf: urls)
            urlCount += urls.count
        }
        lines.append("------")
        return SearchHistoryExportDocument(
            text: lines.joined(separator: "\n") + "\n",
            urlCount: urlCount,
            skippedPaperCount: skippedPaperCount
        )
    }
}
