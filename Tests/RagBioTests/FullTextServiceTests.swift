import Foundation
import Testing
@testable import RagBio

@Suite struct FullTextServiceTests {
    @Test func placeholderTitleCannotAttachAnUnrelatedEuropePMCArticle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MismatchedEuropePMCURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let cacheRoot = try makeTemporaryDirectory().appendingPathComponent("FullText")
        let service = FullTextService(
            session: session,
            cache: FullTextCache(directory: cacheRoot)
        )
        let work = Work(
            id: "https://pubmed.ncbi.nlm.nih.gov/34969511",
            doi: nil,
            title: "[Not Available].",
            publicationDate: "2021-01-01",
            publicationYear: 2021,
            citedByCount: 0,
            authorships: [],
            abstractInvertedIndex: nil,
            primaryLocation: nil,
            bestOpenAccessLocation: nil,
            openAccess: nil,
            contentURLs: nil,
            hasFullText: nil,
            ids: WorkIDs(pmid: "34969511", pmcid: nil),
            locations: [],
            isRetracted: nil,
            type: nil,
            publicationTypes: ["Review"],
            language: "fr",
            abstractPlain: "HER2-low breast cancer is the subject of this review."
        )

        let document = try await service.load(work: work, apiKey: nil)

        #expect(document.source == .abstract)
        #expect(document.paragraphs.first?.text == work.abstractText)
    }

    @Test func fullTextCacheStoresOneDocumentForAllAliasesAndCanBeCleared() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("FullText")
        let cache = FullTextCache(directory: root, maintenanceInterval: 0)
        let document = FullTextDocument(
            workID: "https://openalex.org/W1",
            title: "Example",
            source: .europePMC,
            sourceURL: "https://example.test/fulltext",
            paragraphs: [
                FullTextParagraph(
                    id: "p-1",
                    section: "Results",
                    text: "This paragraph contains enough full-text evidence for cache testing.",
                    ordinal: 1,
                    page: nil
                )
            ],
            loadedAt: Date()
        )
        await cache.save(
            document,
            aliases: [document.workID, "doi:10.1000/example", "pmid:12345"]
        )

        #expect(await cache.load(workID: "doi:10.1000/example") == document)
        let documentFiles = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent != "aliases.json" }
        #expect(documentFiles.count == 1)
        #expect(await cache.sizeInBytes() > 0)

        await cache.removeAll()
        #expect(await cache.sizeInBytes() == 0)
    }

    @Test func fullTextCacheEvictsTheOldestDocumentAboveItsLimit() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("FullText")
        let first = cachedDocument(id: "W-old", marker: "old")
        let second = cachedDocument(id: "W-new", marker: "new")
        let oneDocumentBytes = Int64(try JSONEncoder().encode(first).count)
        let cache = FullTextCache(
            directory: root,
            maximumBytes: oneDocumentBytes + 100,
            maintenanceInterval: 0
        )

        await cache.save(first)
        try await Task.sleep(for: .milliseconds(20))
        await cache.save(second)

        #expect(await cache.load(workID: first.workID) == nil)
        #expect(await cache.load(workID: second.workID) == second)
    }

    @Test func softTimeoutCancelsTheUnderlyingFullTextRequest() async throws {
        SlowFullTextURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SlowFullTextURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let root = try makeTemporaryDirectory().appendingPathComponent("FullText")
        let service = FullTextService(
            session: session,
            cache: FullTextCache(directory: root)
        )
        let startedAt = Date()

        let document = await SearchStore.loadFullTextWithSoftTimeout(
            service: service,
            work: makeWork(),
            apiKey: nil,
            contactEmail: nil,
            semanticScholarAPIKey: nil,
            seconds: 1
        )

        #expect(document == nil)
        #expect(Date().timeIntervalSince(startedAt) < 2.5)
        #expect(SlowFullTextURLProtocol.wasStopped)
    }

    @Test func paragraphEmbeddingCacheReusesMatchingVectorsAndRejectsStaleContent() async throws {
        let root = try makeTemporaryDirectory().appendingPathComponent("FullText")
        let cache = ParagraphEmbeddingCache(directory: root)
        let paragraphs = [
            FullTextParagraph(
                id: "results-1",
                section: "Results",
                text: "Depression scores were measured after childhood gastrointestinal disease.",
                ordinal: 1,
                page: nil
            )
        ]
        let fingerprint = ParagraphEmbeddingCache.contentFingerprint(paragraphs: paragraphs)
        let vector = [0.125, -0.25, 0.75]

        await cache.merge(
            ["results-1": vector],
            workID: "W-cache-test",
            contentFingerprint: fingerprint,
            modelSignature: "test-model",
            dimension: vector.count
        )

        let reused = await cache.vectors(
            workID: "W-cache-test",
            contentFingerprint: fingerprint,
            modelSignature: "test-model",
            dimension: vector.count,
            paragraphIDs: ["results-1"]
        )
        #expect(reused["results-1"]?.count == vector.count)
        #expect(abs((reused["results-1"]?[1] ?? 0) - vector[1]) < 0.000_001)

        let stale = await cache.vectors(
            workID: "W-cache-test",
            contentFingerprint: "different-content",
            modelSignature: "test-model",
            dimension: vector.count,
            paragraphIDs: ["results-1"]
        )
        #expect(stale.isEmpty)
    }

    private func cachedDocument(id: String, marker: String) -> FullTextDocument {
        FullTextDocument(
            workID: id,
            title: marker,
            source: .europePMC,
            sourceURL: "https://example.test/\(marker)",
            paragraphs: [
                FullTextParagraph(
                    id: "p-1",
                    section: "Results",
                    text: String(repeating: "\(marker) evidence ", count: 100),
                    ordinal: 1,
                    page: nil
                )
            ],
            loadedAt: Date()
        )
    }
}

private final class SlowFullTextURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedWasStopped = false

    static var wasStopped: Bool {
        lock.withLock { storedWasStopped }
    }

    static func reset() {
        lock.withLock { storedWasStopped = false }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}

    override func stopLoading() {
        Self.lock.withLock { Self.storedWasStopped = true }
    }
}

private final class MismatchedEuropePMCURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let data: Data
        let contentType: String
        if url.path.hasSuffix("/search") {
            data = Data(
                """
                {
                  "resultList": {
                    "result": [{
                      "id": "99999999",
                      "source": "MED",
                      "pmcid": "PMC9393997",
                      "title": "Coccydynia"
                    }]
                  }
                }
                """.utf8
            )
            contentType = "application/json"
        } else {
            data = Data(
                """
                <article><body><sec><title>Introduction</title><p>
                Coccydynia is pain located in the coccygeal bone and surrounding tissues.
                </p></sec></body></article>
                """.utf8
            )
            contentType = "application/xml"
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
