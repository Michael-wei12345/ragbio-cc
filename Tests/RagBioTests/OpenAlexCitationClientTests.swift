import Foundation
import Testing
@testable import RagBio

@Suite(.serialized) struct OpenAlexCitationClientTests {
    @Test func citationChasingReturnsBackwardAndForwardNeighbors() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAlexCitationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let seed = makeWork(
            id: "https://pubmed.ncbi.nlm.nih.gov/123",
            doi: "https://doi.org/10.1000/review",
            pmid: "123",
            title: "Systematic review"
        )

        let works = await OpenAlexClient(session: session).citationNeighbors(
            for: [seed],
            relevanceQuery: "adjuvant trastuzumab",
            apiKey: nil,
            referencesPerSeed: 2,
            citationsPerSeed: 1
        )

        #expect(Set(works.map(\.id)) == [
            "https://openalex.org/W10",
            "https://openalex.org/W11",
            "https://openalex.org/W12"
        ])
    }

    @Test func searchSendsStartYearAndOpenAccessFilters() async throws {
        OpenAlexSearchFilterURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAlexSearchFilterURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        _ = try await OpenAlexClient(session: session).search(
            query: "filter-\(UUID().uuidString)",
            sort: .relevance,
            fromYear: 2018,
            openAccessOnly: true,
            apiKey: nil,
            page: 1,
            perPage: 20
        )

        #expect(
            OpenAlexSearchFilterURLProtocol.filter
                == "is_retracted:false,from_publication_date:2018-01-01,is_oa:true"
        )
    }
}

private final class OpenAlexSearchFilterURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedFilter = ""

    static var filter: String {
        lock.lock()
        defer { lock.unlock() }
        return storedFilter
    }

    static func reset() {
        lock.lock()
        storedFilter = ""
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let filter = components?.queryItems?.first(where: { $0.name == "filter" })?.value ?? ""
        Self.lock.lock()
        Self.storedFilter = filter
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"meta":{"count":0},"results":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OpenAlexCitationURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let filter = components?.queryItems?.first(where: { $0.name == "filter" })?.value ?? ""
        let data: Data
        if url.path.contains("/works/doi:") {
            data = Data(
                #"{"id":"https://openalex.org/W1","referenced_works":["https://openalex.org/W10","https://openalex.org/W11"]}"#.utf8
            )
        } else if filter.hasPrefix("openalex_id:") {
            data = response(ids: ["W10", "W11"])
        } else {
            data = response(ids: ["W12"])
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func response(ids: [String]) -> Data {
        let results: [[String: Any]] = ids.map { id in
            [
                "id": "https://openalex.org/\(id)",
                "title": "Citation neighbor \(id)",
                "cited_by_count": 0,
                "authorships": [],
                "locations": []
            ]
        }
        return try! JSONSerialization.data(
            withJSONObject: ["meta": ["count": results.count], "results": results]
        )
    }
}
