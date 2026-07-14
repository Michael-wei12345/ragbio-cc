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
    }
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
