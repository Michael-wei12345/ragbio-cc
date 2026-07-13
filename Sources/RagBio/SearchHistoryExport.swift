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
           let url = normalizedHTTPURL("https://doi.org/\(doi)") {
            return url
        }
        if let pmid = work.normalizedPMID,
           !pmid.isEmpty,
           pmid.allSatisfy(\.isNumber),
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
        let shortID = work.shortID.uppercased()
        guard shortID.hasPrefix("W"),
              !shortID.dropFirst().isEmpty,
              shortID.dropFirst().allSatisfy(\.isNumber) else { return nil }
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
        if (scheme == "http" && components.port == 80)
            || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        return components.url
    }

    private static func isIdentifierHost(_ host: String?, domain: String) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == domain || host.hasSuffix(".\(domain)")
    }

    private static func isDirectPDF(_ url: URL) -> Bool {
        url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
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
