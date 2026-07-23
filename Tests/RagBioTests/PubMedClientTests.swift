import Foundation
import Testing
@testable import RagBio

@Suite struct PubMedClientTests {
    @Test func publicationTypesArePreservedForCandidateFiltering() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PubMedPublicationTypeURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let works = try await PubMedClient(session: session).search(
            query: "protocol",
            fromYear: nil,
            maxResults: 1,
            contactEmail: nil
        )
        let work = try #require(works.first)

        #expect(work.publicationTypes == ["Journal Article", "Clinical Trial Protocol"])
        #expect(work.nonPrimaryPublicationKind == .studyProtocol)
        #expect(work.isOpenAccess)
        #expect(work.hasAvailableFullText)
        #expect(
            work.bestOpenAccessLocation?.landingPageURL
                == "https://pmc.ncbi.nlm.nih.gov/articles/PMC12345/"
        )
    }

    @Test func vernacularTitleReplacesUnavailableArticleTitle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PubMedVernacularTitleURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let works = try await PubMedClient(session: session).search(
            query: "HER2-low",
            fromYear: nil,
            maxResults: 1,
            contactEmail: nil
        )
        let work = try #require(works.first)

        #expect(
            work.title
                == "« HER2-faible », un nouveau concept: HER2-low breast cancer treatment strategy."
        )
    }

    @Test func missingPubMedTitlesUseEnglishFallback() {
        #expect(
            BibliographicTitleResolver.preferred(
                articleTitle: "[Not Available].",
                vernacularTitle: ""
            ) == "Title unavailable"
        )
    }

    @Test func largePubMedResultsAreFetchedInBoundedBatches() async throws {
        PubMedBatchURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PubMedBatchURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let works = try await PubMedClient(session: session).search(
            query: "large result",
            fromYear: nil,
            maxResults: 201,
            contactEmail: nil
        )

        #expect(PubMedBatchURLProtocol.fetchSizes == [200, 1])
        #expect(works.map(\.normalizedPMID) == ["1", "201"])
    }

    @Test func startYearIsSentToPubMedESearch() async throws {
        PubMedDateURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PubMedDateURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        _ = try await PubMedClient(session: session).search(
            query: "year filter",
            fromYear: 2018,
            maxResults: 10,
            contactEmail: nil
        )

        #expect(PubMedDateURLProtocol.queryItems["mindate"] == "2018")
        #expect(PubMedDateURLProtocol.queryItems["datetype"] == "pdat")
        #expect(
            PubMedDateURLProtocol.queryItems["maxdate"]
                == String(Calendar.current.component(.year, from: Date()))
        )
    }
}

private final class PubMedDateURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedQueryItems: [String: String] = [:]

    static var queryItems: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return storedQueryItems
    }

    static func reset() {
        lock.lock()
        storedQueryItems = [:]
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        Self.lock.lock()
        Self.storedQueryItems = Dictionary(
            uniqueKeysWithValues: items.compactMap { item in
                item.value.map { (item.name, $0) }
            }
        )
        Self.lock.unlock()
        let data = Data(#"{"esearchresult":{"idlist":[]}}"#.utf8)
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
}

private final class PubMedBatchURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedFetchSizes: [Int] = []

    static var fetchSizes: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storedFetchSizes
    }

    static func reset() {
        lock.lock()
        storedFetchSizes = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let data: Data
        if url.path.hasSuffix("esearch.fcgi") {
            let ids = (1...201).map(String.init)
            data = try! JSONSerialization.data(
                withJSONObject: ["esearchresult": ["idlist": ids]]
            )
        } else {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let ids = components?.queryItems?.first(where: { $0.name == "id" })?
                .value?.split(separator: ",").map(String.init) ?? []
            Self.lock.lock()
            Self.storedFetchSizes.append(ids.count)
            Self.lock.unlock()
            let pmid = ids.first ?? "0"
            data = Data(
                """
                <PubmedArticleSet>
                  <PubmedArticle>
                    <MedlineCitation>
                      <PMID>\(pmid)</PMID>
                      <Article>
                        <ArticleTitle>Article \(pmid)</ArticleTitle>
                        <Journal><Title>Example Journal</Title></Journal>
                      </Article>
                    </MedlineCitation>
                  </PubmedArticle>
                </PubmedArticleSet>
                """.utf8
            )
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/xml"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class PubMedPublicationTypeURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let data: Data
        if url.path.hasSuffix("esearch.fcgi") {
            data = Data(#"{"esearchresult":{"idlist":["12345"]}}"#.utf8)
        } else {
            data = Data(
                """
                <PubmedArticleSet>
                  <PubmedArticle>
                    <MedlineCitation>
                      <PMID>12345</PMID>
                      <Article>
                        <ArticleTitle>Registered trial protocol</ArticleTitle>
                        <Journal><Title>Example Journal</Title></Journal>
                        <PublicationTypeList>
                          <PublicationType>Journal Article</PublicationType>
                          <PublicationType>Clinical Trial Protocol</PublicationType>
                        </PublicationTypeList>
                      </Article>
                    </MedlineCitation>
                    <PubmedData>
                      <ArticleIdList>
                        <ArticleId IdType="pmc">PMC12345</ArticleId>
                      </ArticleIdList>
                    </PubmedData>
                  </PubmedArticle>
                </PubmedArticleSet>
                """.utf8
            )
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/xml"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class PubMedVernacularTitleURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let data: Data
        if url.path.hasSuffix("esearch.fcgi") {
            data = Data(#"{"esearchresult":{"idlist":["34969511"]}}"#.utf8)
        } else {
            data = Data(
                """
                <PubmedArticleSet>
                  <PubmedArticle>
                    <MedlineCitation>
                      <PMID>34969511</PMID>
                      <Article>
                        <ArticleTitle>[Not Available].</ArticleTitle>
                        <VernacularTitle>« HER2-faible », un nouveau concept: HER2-low breast cancer treatment strategy.</VernacularTitle>
                        <Journal><Title>Bulletin du cancer</Title></Journal>
                      </Article>
                    </MedlineCitation>
                  </PubmedArticle>
                </PubmedArticleSet>
                """.utf8
            )
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/xml"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
