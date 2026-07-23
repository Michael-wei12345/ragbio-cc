import Foundation

struct OpenAlexClient {
    var session: URLSession = .shared
    private static let responseCache = OpenAlexSearchCache()

    func search(
        query: String,
        sort: SearchSort,
        fromYear: Int?,
        openAccessOnly: Bool,
        apiKey: String?,
        page: Int,
        perPage: Int,
        timeout: TimeInterval = 45,
        maxAttempts: Int = 3
    ) async throws -> OpenAlexResponse {
        let searchQuery = OpenAlexQueryNormalizer.normalize(query)
        let cacheKey = [
            searchQuery.lowercased(),
            sort.rawValue,
            fromYear.map(String.init) ?? "",
            openAccessOnly ? "oa" : "all",
            String(page),
            String(perPage)
        ].joined(separator: "|")
        if let cached = await Self.responseCache.data(for: cacheKey) {
            return try JSONDecoder().decode(OpenAlexResponse.self, from: cached)
        }

        var components = URLComponents(string: "https://api.openalex.org/works")
        var items = [
            URLQueryItem(name: "search", value: searchQuery),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "per-page", value: String(perPage)),
            URLQueryItem(
                name: "select",
                value: [
                    "id", "doi", "title", "publication_date", "publication_year",
                    "cited_by_count", "authorships", "abstract_inverted_index",
                    "primary_location", "best_oa_location", "open_access",
                    "content_urls", "has_fulltext", "ids", "locations",
                    "is_retracted", "type", "language"
                ].joined(separator: ",")
            )
        ]

        if let sortValue = sort.apiValue {
            items.append(URLQueryItem(name: "sort", value: sortValue))
        }

        var filters: [String] = ["is_retracted:false"]
        if let fromYear {
            filters.append("from_publication_date:\(fromYear)-01-01")
        }
        if openAccessOnly {
            filters.append("is_oa:true")
        }
        items.append(URLQueryItem(name: "filter", value: filters.joined(separator: ",")))

        if let apiKey, !apiKey.isEmpty {
            items.append(URLQueryItem(name: "api_key", value: apiKey))
        }

        components?.queryItems = items
        guard let url = components?.url else { throw SearchError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("RagBio/0.1 (macOS academic search client)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var lastError: Error?
        for attempt in 0..<maxAttempts {
            var retryDelay = attempt == 0 ? 1 : 3
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SearchError.invalidResponse
                }
                if (200..<300).contains(http.statusCode) {
                    let decoded = try JSONDecoder().decode(OpenAlexResponse.self, from: data)
                    await Self.responseCache.store(data, for: cacheKey)
                    return decoded
                }
                let message = String(data: data, encoding: .utf8) ?? "未知错误"
                let error = SearchError.api(status: http.statusCode, message: message)
                guard http.statusCode == 429 || (500...599).contains(http.statusCode),
                      attempt < maxAttempts - 1 else {
                    throw error
                }
                lastError = error
                if let raw = http.value(forHTTPHeaderField: "Retry-After"),
                   let seconds = Int(raw) {
                    retryDelay = min(30, max(1, seconds))
                }
            } catch let error as URLError
            where [
                .timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost
            ].contains(error.code) && attempt < maxAttempts - 1 {
                lastError = error
            }
            try await Task.sleep(for: .seconds(retryDelay))
        }
        throw lastError ?? SearchError.invalidResponse
    }
}

private actor OpenAlexSearchCache {
    private struct Entry {
        let data: Data
        let storedAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let lifetime: TimeInterval = 30 * 60

    func data(for key: String) -> Data? {
        guard let entry = entries[key] else { return nil }
        guard Date().timeIntervalSince(entry.storedAt) < lifetime else {
            entries.removeValue(forKey: key)
            return nil
        }
        return entry.data
    }

    func store(_ data: Data, for key: String) {
        entries[key] = Entry(data: data, storedAt: Date())
        if entries.count > 100 {
            let oldest = entries.min { $0.value.storedAt < $1.value.storedAt }?.key
            if let oldest {
                entries.removeValue(forKey: oldest)
            }
        }
    }
}
