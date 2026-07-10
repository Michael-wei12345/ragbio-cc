import Foundation

actor FullTextService {
    private let session: URLSession
    private let cache: FullTextCache
    private let failureCooldown: TimeInterval = 10 * 60
    private var failedEndpointCooldowns: [String: Date] = [:]

    init(session: URLSession = .shared, cache: FullTextCache = FullTextCache()) {
        self.session = session
        self.cache = cache
    }

    func load(
        work: Work,
        apiKey: String?,
        contactEmail: String? = nil,
        semanticScholarAPIKey: String? = nil
    ) async throws -> FullTextDocument {
        if let cached = await cache.load(workID: work.id) {
            return cached
        }

        var errors: [String] = []

        do {
            let document = try await fetchEuropePMC(work: work)
            await cache.save(document)
            return document
        } catch {
            errors.append("Europe PMC：\(error.localizedDescription)")
        }

        if let xmlURL = work.contentURLs?.grobidXML {
            if let apiKey, !apiKey.isEmpty {
                do {
                    let data = try await fetchData(
                        from: authenticatedContentURL(xmlURL, apiKey: apiKey),
                        accept: "application/xml,text/xml"
                    )
                    let document = try StructuredXMLParser().parse(
                        data: data,
                        workID: work.id,
                        title: work.title,
                        source: .openAlexTEI,
                        sourceURL: xmlURL
                    )
                    await cache.save(document)
                    return document
                } catch {
                    errors.append("OpenAlex TEI：\(error.localizedDescription)")
                }
            } else {
                errors.append("OpenAlex TEI：需要 API Key")
            }
        }

        var publicPDFs = [
            work.bestOpenAccessLocation?.pdfURL,
            work.primaryLocation?.pdfURL
        ].compactMap { $0 }
        publicPDFs.append(contentsOf: work.locations.compactMap(\.pdfURL))
        publicPDFs = publicPDFs.uniqued()
        for pdfURL in publicPDFs {
            do {
                let document = try await fetchPDF(
                    urlString: pdfURL,
                    work: work,
                    source: .publisherPDF,
                    apiKey: nil
                )
                await cache.save(document)
                return document
            } catch {
                errors.append("开放 PDF：\(error.localizedDescription)")
            }
        }

        if let doi = work.normalizedDOI,
           let contactEmail,
           contactEmail.contains("@") {
            do {
                let unpaywallURLs = try await fetchUnpaywallPDFURLs(
                    doi: doi,
                    contactEmail: contactEmail
                )
                for pdfURL in unpaywallURLs where !publicPDFs.contains(pdfURL) {
                    do {
                        let document = try await fetchPDF(
                            urlString: pdfURL,
                            work: work,
                            source: .unpaywallPDF,
                            apiKey: nil
                        )
                        await cache.save(document)
                        return document
                    } catch {
                        errors.append("Unpaywall PDF：\(error.localizedDescription)")
                    }
                }
            } catch {
                errors.append("Unpaywall：\(error.localizedDescription)")
            }
        }

        if let openAlexPDF = work.contentURLs?.pdf {
            if let apiKey, !apiKey.isEmpty {
                do {
                    let document = try await fetchPDF(
                        urlString: openAlexPDF,
                        work: work,
                        source: .openAlexPDF,
                        apiKey: apiKey
                    )
                    await cache.save(document)
                    return document
                } catch {
                    errors.append("OpenAlex PDF：\(error.localizedDescription)")
                }
            } else {
                errors.append("OpenAlex PDF：需要 API Key")
            }
        }

        if let doi = work.normalizedDOI {
            do {
                if let semanticScholarPDF = try await fetchSemanticScholarPDFURL(
                    doi: doi,
                    apiKey: semanticScholarAPIKey
                ) {
                    let document = try await fetchPDF(
                        urlString: semanticScholarPDF,
                        work: work,
                        source: .publisherPDF,
                        apiKey: nil
                    )
                    await cache.save(document)
                    return document
                }
            } catch {
                errors.append("Semantic Scholar：\(error.localizedDescription)")
            }
        }

        if let abstract = work.abstractText {
            let paragraph = FullTextParagraph(
                id: "abstract-1",
                section: "摘要",
                text: abstract,
                ordinal: 1,
                page: nil
            )
            return FullTextDocument(
                workID: work.id,
                title: work.title,
                source: .abstract,
                sourceURL: work.landingPageURL?.absoluteString,
                paragraphs: [paragraph],
                loadedAt: Date()
            )
        }

        if errors.contains(where: { $0.contains("需要 API Key") }) {
            throw FullTextError.network(
                "未能从开放来源取得全文。OpenAlex 全文需要免费 API Key；也可以导入本地 PDF。\n"
                    + errors.joined(separator: "\n")
            )
        }
        throw FullTextError.network(
            errors.isEmpty
                ? FullTextError.noUsableSource.localizedDescription
                : errors.joined(separator: "\n")
        )
    }

    func loadForPageAnalysis(work: Work) async throws -> FullTextDocument {
        if let cached = await cache.load(workID: work.id) {
            return cached
        }
        guard let abstract = work.abstractText else {
            throw FullTextError.noUsableSource
        }
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

    func importPDF(url: URL, work: Work) async throws -> FullTextDocument {
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let document = try PDFTextParser.parse(
            url: url,
            workID: work.id,
            title: work.title,
            source: .importedPDF,
            sourceURL: url.path
        )
        await cache.save(document)
        return document
    }

    func clearCache(workID: String) async {
        await cache.remove(workID: workID)
        failedEndpointCooldowns.removeAll()
    }

    private func fetchEuropePMC(work: Work) async throws -> FullTextDocument {
        if let pmcid = work.normalizedPMCID {
            return try await fetchEuropePMCXML(pmcid: pmcid, work: work)
        }

        var queries: [String] = []
        if let doi = work.normalizedDOI {
            queries.append("DOI:\(doi)")
        }
        if let pmid = work.normalizedPMID {
            queries.append("EXT_ID:\(pmid) AND SRC:MED")
        }
        let escapedTitle = work.title.replacingOccurrences(of: "\"", with: "\\\"")
        if let year = work.publicationYear {
            queries.append("TITLE:\"\(escapedTitle)\" AND FIRST_PDATE:[\(year) TO \(year)]")
        } else {
            queries.append("TITLE:\"\(escapedTitle)\"")
        }

        for query in queries {
            var search = URLComponents(
                string: "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
            )
            search?.queryItems = [
                URLQueryItem(name: "query", value: query),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "resultType", value: "core"),
                URLQueryItem(name: "pageSize", value: "3")
            ]
            guard let searchURL = search?.url else { continue }
            let searchData = try await fetchData(from: searchURL, accept: "application/json")
            let result = try JSONDecoder().decode(EuropePMCSearchResponse.self, from: searchData)
            if let pmcid = result.resultList.result
                .first(where: { $0.pmcid != nil })?.pmcid {
                return try await fetchEuropePMCXML(pmcid: pmcid, work: work)
            }
        }
        throw FullTextError.noUsableSource
    }

    private func fetchEuropePMCXML(
        pmcid: String,
        work: Work
    ) async throws -> FullTextDocument {
        let normalized = pmcid.uppercased().hasPrefix("PMC") ? pmcid : "PMC\(pmcid)"
        let xmlURL = URL(
            string: "https://www.ebi.ac.uk/europepmc/webservices/rest/\(normalized)/fullTextXML"
        )!
        let xml = try await fetchData(from: xmlURL, accept: "application/xml,text/xml")
        return try StructuredXMLParser().parse(
            data: xml,
            workID: work.id,
            title: work.title,
            source: .europePMC,
            sourceURL: xmlURL.absoluteString
        )
    }

    private func fetchUnpaywallPDFURLs(
        doi: String,
        contactEmail: String
    ) async throws -> [String] {
        guard var components = URLComponents(
            string: "https://api.unpaywall.org/v2/\(doi)"
        ) else {
            throw SearchError.invalidURL
        }
        components.queryItems = [URLQueryItem(name: "email", value: contactEmail)]
        guard let url = components.url else { throw SearchError.invalidURL }
        let data = try await fetchData(from: url, accept: "application/json")
        let response = try JSONDecoder().decode(UnpaywallResponse.self, from: data)
        var urls = response.oaLocations.compactMap(\.urlForPDF)
        if let best = response.bestOpenAccessLocation?.urlForPDF {
            urls.insert(best, at: 0)
        }
        return urls.uniqued()
    }

    private func fetchSemanticScholarPDFURL(doi: String, apiKey: String?) async throws -> String? {
        let identifier = "DOI:\(doi)"
            .addingPercentEncoding(
                withAllowedCharacters: CharacterSet.alphanumerics.union(
                    CharacterSet(charactersIn: "-._~:")
                )
            )
            ?? "DOI:\(doi)"
        var components = URLComponents(
            string: "https://api.semanticscholar.org/graph/v1/paper/\(identifier)"
        )
        components?.queryItems = [
            URLQueryItem(name: "fields", value: "openAccessPdf,title,externalIds")
        ]
        guard let url = components?.url else { throw SearchError.invalidURL }
        let headers = apiKey?.isEmpty == false ? ["x-api-key": apiKey!] : [:]
        let data = try await fetchData(from: url, accept: "application/json", headers: headers)
        return try JSONDecoder().decode(
            SemanticScholarPaper.self,
            from: data
        ).openAccessPDF?.url
    }

    private func fetchPDF(
        urlString: String,
        work: Work,
        source: FullTextSource,
        apiKey: String?
    ) async throws -> FullTextDocument {
        guard let rawURL = URL(string: urlString) else {
            throw SearchError.invalidURL
        }
        let url = apiKey.map { authenticatedContentURL(urlString, apiKey: $0) } ?? rawURL
        let data = try await fetchData(from: url, accept: "application/pdf")
        if let endpoint = UserDefaults.standard.string(forKey: SettingsKeys.grobidEndpoint),
           !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let document = try? await GROBIDClient.parse(
               pdfData: data,
               workID: work.id,
               title: work.title,
               sourceURL: urlString,
               endpoint: endpoint
           ) {
            return document
        }
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: temporaryURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        return try PDFTextParser.parse(
            url: temporaryURL,
            workID: work.id,
            title: work.title,
            source: source,
            sourceURL: urlString
        )
    }

    private func fetchData(
        from url: URL,
        accept: String,
        headers: [String: String] = [:]
    ) async throws -> Data {
        let cooldownKey = Self.failureCooldownKey(for: url)
        if let message = failureCooldownMessage(for: cooldownKey, url: url) {
            throw FullTextError.network(message)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(
            "RagBio/0.2 (macOS academic evidence client)",
            forHTTPHeaderField: "User-Agent"
        )
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw SearchError.invalidResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data.prefix(500), encoding: .utf8) ?? "未知错误"
                throw SearchError.api(status: http.statusCode, message: body)
            }
            failedEndpointCooldowns.removeValue(forKey: cooldownKey)
            return data
        } catch let error as CancellationError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw error
        } catch {
            failedEndpointCooldowns[cooldownKey] = Date().addingTimeInterval(failureCooldown)
            throw error
        }
    }

    private func failureCooldownMessage(for key: String, url: URL) -> String? {
        guard let expiresAt = failedEndpointCooldowns[key] else { return nil }
        let remaining = expiresAt.timeIntervalSinceNow
        guard remaining > 0 else {
            failedEndpointCooldowns.removeValue(forKey: key)
            return nil
        }
        let minutes = max(1, Int(ceil(remaining / 60)))
        let host = url.host ?? "该来源"
        return "近期已跳过重复失败的全文来源 \(host)，\(minutes) 分钟后会自动再试；如果你有原文，请直接导入 PDF。"
    }

    private nonisolated static func failureCooldownKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.user = nil
        components.password = nil
        components.fragment = nil
        components.queryItems = components.queryItems?
            .filter { item in
                let name = item.name.lowercased()
                return name != "api_key" && name != "email"
            }
            .sorted { lhs, rhs in
                lhs.name == rhs.name
                    ? (lhs.value ?? "") < (rhs.value ?? "")
                    : lhs.name < rhs.name
            }
        return components.url?.absoluteString ?? url.absoluteString
    }

    private func authenticatedContentURL(_ value: String, apiKey: String) -> URL {
        guard var components = URLComponents(string: value) else {
            return URL(string: value)!
        }
        var items = components.queryItems ?? []
        items.removeAll { $0.name == "api_key" }
        items.append(URLQueryItem(name: "api_key", value: apiKey))
        components.queryItems = items
        return components.url ?? URL(string: value)!
    }
}

private struct EuropePMCSearchResponse: Decodable {
    let resultList: ResultList

    struct ResultList: Decodable {
        let result: [Result]
    }

    struct Result: Decodable {
        let pmcid: String?
        let title: String?
    }
}

private struct UnpaywallResponse: Decodable {
    let bestOpenAccessLocation: UnpaywallLocation?
    let oaLocations: [UnpaywallLocation]

    enum CodingKeys: String, CodingKey {
        case bestOpenAccessLocation = "best_oa_location"
        case oaLocations = "oa_locations"
    }
}

private struct UnpaywallLocation: Decodable {
    let urlForPDF: String?

    enum CodingKeys: String, CodingKey {
        case urlForPDF = "url_for_pdf"
    }
}

private struct SemanticScholarPaper: Decodable {
    let openAccessPDF: SemanticScholarPDF?

    enum CodingKeys: String, CodingKey {
        case openAccessPDF = "openAccessPdf"
    }
}

private struct SemanticScholarPDF: Decodable {
    let url: String?
}

actor FullTextCache {
    private let directory: URL

    init() {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        directory = applicationSupport
            .appendingPathComponent("RagBio", isDirectory: true)
            .appendingPathComponent("FullText", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
    }

    func load(workID: String) -> FullTextDocument? {
        let url = fileURL(workID: workID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FullTextDocument.self, from: data)
    }

    func save(_ document: FullTextDocument) {
        guard document.source.isFullText,
              let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: fileURL(workID: document.workID), options: .atomic)
    }

    func remove(workID: String) {
        try? FileManager.default.removeItem(at: fileURL(workID: workID))
    }

    private func fileURL(workID: String) -> URL {
        let safeID = workID
            .replacingOccurrences(of: "https://openalex.org/", with: "")
            .replacingOccurrences(
                of: "[^A-Za-z0-9._-]",
                with: "_",
                options: .regularExpression
            )
        return directory.appendingPathComponent(safeID).appendingPathExtension("json")
    }
}
