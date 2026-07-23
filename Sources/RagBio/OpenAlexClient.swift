import Foundation

struct OpenAlexClient {
    var session: URLSession = .shared
    private static let responseCache = OpenAlexSearchCache()
    private static let workSelectFields = [
        "id", "doi", "title", "publication_date", "publication_year",
        "cited_by_count", "authorships", "abstract_inverted_index",
        "primary_location", "best_oa_location", "open_access",
        "content_urls", "has_fulltext", "ids", "locations",
        "is_retracted", "type", "language"
    ].joined(separator: ",")

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
                value: Self.workSelectFields
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

        let data = try await requestData(request, maxAttempts: maxAttempts)
        let decoded = try JSONDecoder().decode(OpenAlexResponse.self, from: data)
        await Self.responseCache.store(data, for: cacheKey)
        return decoded
    }

    /// Supplementary one-hop citation chasing from a small number of review or meta-analysis
    /// seeds. Returned records still go through deduplication and conservative eligibility triage.
    func citationNeighbors(
        for seeds: [Work],
        relevanceQuery: String,
        apiKey: String?,
        referencesPerSeed: Int = 120,
        citationsPerSeed: Int = 30
    ) async -> [Work] {
        var neighbors: [Work] = []
        for seed in seeds {
            guard !Task.isCancelled,
                  let descriptor = try? await citationDescriptor(for: seed, apiKey: apiKey) else {
                continue
            }
            let referenceIDs = Array(descriptor.referencedWorks.prefix(referencesPerSeed))
            for start in stride(from: 0, to: referenceIDs.count, by: 100) {
                let end = min(start + 100, referenceIDs.count)
                if let works = try? await works(
                    matchingFilter: "openalex_id:"
                        + referenceIDs[start..<end].map(Self.shortOpenAlexID).joined(separator: "|"),
                    search: nil,
                    perPage: end - start,
                    apiKey: apiKey
                ) {
                    neighbors += works
                }
            }
            if citationsPerSeed > 0,
               let citing = try? await works(
                   matchingFilter: "cites:\(Self.shortOpenAlexID(descriptor.id)),is_retracted:false",
                   search: relevanceQuery,
                   perPage: citationsPerSeed,
                   apiKey: apiKey
               ) {
                neighbors += citing
            }
        }
        return neighbors
    }

    private struct CitationDescriptor: Decodable {
        let id: String
        let referencedWorks: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case referencedWorks = "referenced_works"
        }
    }

    private func citationDescriptor(for work: Work, apiKey: String?) async throws
        -> CitationDescriptor
    {
        let identifier: String
        if work.id.lowercased().contains("openalex.org/w") {
            identifier = Self.shortOpenAlexID(work.id)
        } else if let doi = work.normalizedDOI {
            identifier = "doi:\(doi)"
        } else if let pmid = work.normalizedPMID {
            identifier = "pmid:\(pmid)"
        } else {
            throw SearchError.invalidURL
        }
        guard let encoded = identifier.addingPercentEncoding(
            withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(
                CharacterSet(charactersIn: "/")
            )
        ) else {
            throw SearchError.invalidURL
        }
        var components = URLComponents(
            string: "https://api.openalex.org/works/\(encoded)"
        )
        var items = [URLQueryItem(name: "select", value: "id,referenced_works")]
        if let apiKey, !apiKey.isEmpty {
            items.append(URLQueryItem(name: "api_key", value: apiKey))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw SearchError.invalidURL }
        let data = try await requestData(url)
        return try JSONDecoder().decode(CitationDescriptor.self, from: data)
    }

    private func works(
        matchingFilter filter: String,
        search: String?,
        perPage: Int,
        apiKey: String?
    ) async throws -> [Work] {
        var components = URLComponents(string: "https://api.openalex.org/works")
        var items = [
            URLQueryItem(name: "filter", value: filter),
            URLQueryItem(name: "per-page", value: String(min(200, max(1, perPage)))),
            URLQueryItem(name: "select", value: Self.workSelectFields)
        ]
        if let search, !search.isEmpty {
            items.append(URLQueryItem(name: "search", value: search))
        }
        if let apiKey, !apiKey.isEmpty {
            items.append(URLQueryItem(name: "api_key", value: apiKey))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw SearchError.invalidURL }
        let data = try await requestData(url)
        return try JSONDecoder().decode(OpenAlexResponse.self, from: data).results
    }

    private func requestData(_ url: URL, maxAttempts: Int = 3) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("RagBio/0.1 (macOS academic search client)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await requestData(request, maxAttempts: maxAttempts)
    }

    private func requestData(_ request: URLRequest, maxAttempts: Int) async throws -> Data {
        var lastError: Error?
        for attempt in 0..<maxAttempts {
            var retryDelay = min(8, 1 << attempt)
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw SearchError.invalidResponse
                }
                if (200..<300).contains(http.statusCode) { return data }
                let error = SearchError.api(
                    status: http.statusCode,
                    message: String(data: data, encoding: .utf8) ?? "未知错误"
                )
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

    private static func shortOpenAlexID(_ value: String) -> String {
        value.split(separator: "/").last.map(String.init) ?? value
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
