import Foundation
import Testing
@testable import RagBio

@Suite struct AIEvidenceRankingTests {
    @Test func evidenceRankingSendsRetrievedPassagesToTheModel() async throws {
        EvidenceRankingURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [EvidenceRankingURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let work = makeWork(title: "Poliovirus paper")
        let paragraph = FullTextParagraph(
            id: "p1",
            section: "Results",
            text: "POLIO_ETIOLOGY_MARKER identifies the causal viral mechanism.",
            ordinal: 1,
            page: 3
        )
        let input = AIEvidenceRankingInput(
            work: work,
            abstract: "Abstract evidence",
            passages: [
                PassageHit(id: "hit-1", paragraph: paragraph, score: 1, matchedTerms: ["polio"])
            ],
            source: .europePMC
        )
        let configuration = AIProviderConfiguration(
            provider: .openAI,
            apiKey: "test-key",
            model: "test-model",
            baseURL: "https://example.test"
        )

        let ranked = try await AIQueryPlanner(session: session).rankEvidenceBatch(
            description: "Etiology of poliomyelitis",
            inputs: [input],
            configuration: configuration
        )

        #expect(ranked.map(\.index) == [0])
        #expect(ranked.map(\.score) == [91])
        #expect(ranked.map(\.relevant) == [true])
        #expect(ranked.map(\.reason) == ["病因相关"])
        #expect(EvidenceRankingURLProtocol.lastPrompt?.contains("POLIO_ETIOLOGY_MARKER") == true)
    }

    @Test func pageRankingReplacesOnlyTheRequestedPage() {
        let works = (1...45).map { makeWork(id: "W\($0)", doi: "10.1000/\($0)") }
        let replacement = Array(works[20..<40].reversed())

        let ranked = SearchStore.replacingPage(
            in: works,
            page: 2,
            pageSize: 20,
            with: replacement
        )

        #expect(Array(ranked[0..<20]).map(\.id) == Array(works[0..<20]).map(\.id))
        #expect(Array(ranked[20..<40]).map(\.id) == replacement.map(\.id))
        #expect(Array(ranked[40..<45]).map(\.id) == Array(works[40..<45]).map(\.id))
    }

    @MainActor
    @Test func restoredHistoryUsesTheCurrentPagesCachedFineRankingState() {
        let works = (1...25).map { makeWork(id: "W\($0)", doi: "10.1000/\($0)") }
        var record = makeRecord(query: "polio", works: works, date: Date())
        record.snapshot.currentPage = 2
        record.snapshot.completedAIStage = .evidenceRanking
        record.snapshot.aiEvidenceLevels = Dictionary(
            uniqueKeysWithValues: works.enumerated().map { index, work in
                (work.id, index < 20 ? "AI 全文精排" : "AI 摘要精排")
            }
        )
        let store = SearchStore(restoreOnInit: false)

        store.restoreHistoryRecord(record)

        #expect(store.aiSecondRerankState == .completed(fullText: 0, abstractOnly: 5, retained: 25))
    }

    @MainActor
    @Test func restoredLocalFallbackKeepsTheFailureNoticeVisible() {
        let works = (1...5).map { makeWork(id: "W\($0)", doi: "10.1000/\($0)") }
        var record = makeRecord(query: "polio", works: works, date: Date())
        record.snapshot.aiEvidenceLevels = Dictionary(
            uniqueKeysWithValues: works.map { ($0.id, "本地摘要排序") }
        )
        let store = SearchStore(restoreOnInit: false)

        store.restoreHistoryRecord(record)

        #expect(
            store.aiSecondRerankState
                == .failed("第 1 页 AI 全文精排此前失败。当前使用本地全文证据排序。")
        )
    }

    @MainActor
    @Test func restoredLegacyRankingHidesObsoleteCoarseStatusText() {
        var record = makeRecord(query: "polio", works: [makeWork()], date: Date())
        record.snapshot.aiSearchNotice = "AI 粗排暂未返回，当前只显示临时候选"
        record.snapshot.searchTimingSummary = "首屏 45.4 秒 · 临时候选 · 证据初排 0.0 秒 · 全文补强 32.8 秒"
        let store = SearchStore(restoreOnInit: false)

        store.restoreHistoryRecord(record)

        #expect(store.aiSearchNotice == nil)
        #expect(store.searchTimingSummary == nil)
    }
}

private final class EvidenceRankingURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedPrompt: String?

    static var lastPrompt: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedPrompt
    }

    static func reset() {
        lock.lock()
        storedPrompt = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.flatMap(Self.read)
        let prompt: String? = body.flatMap { body in
            guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let messages = root["messages"] as? [[String: Any]],
                  let user = messages.last,
                  let content = user["content"] as? String else { return nil }
            return content
        }
        Self.lock.lock()
        Self.storedPrompt = prompt
        Self.lock.unlock()

        let ranking = #"{"rankings":[{"index":0,"score":91,"relevant":true,"reason":"病因相关"}]}"#
        let responseObject: [String: Any] = [
            "choices": [["message": ["content": ranking]]]
        ]
        let data = try! JSONSerialization.data(withJSONObject: responseObject)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
