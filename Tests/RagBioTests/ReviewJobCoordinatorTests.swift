import Foundation
import Testing
@testable import RagBio

@Suite
@MainActor
struct ReviewJobCoordinatorTests {
    @Test func connectedUserMovesDirectlyToReviewConfirmation() async throws {
        let status = FakeAuthorizationProcess(lines: [
            #"{"type":"auth.status","requestId":"status","method":"chatgpt"}"#
        ])
        let factory = AuthorizationProcessFactory(processes: [status])
        let coordinator = makeCoordinator(factory: factory)

        coordinator.prepare(record: makeReviewRecord())
        try await waitForStage(.ready, coordinator: coordinator)

        #expect(factory.createdCount == 1)
        #expect(status.commandText.contains(#""type":"auth.status""#))
    }

    @Test func signedOutUserIsLoggedInBeforeReviewConfirmation() async throws {
        let status = FakeAuthorizationProcess(lines: [
            #"{"type":"auth.status","requestId":"status","method":"signedOut"}"#
        ])
        let login = FakeAuthorizationProcess(lines: [
            #"{"type":"auth.login.started","requestId":"login"}"#,
            #"{"type":"auth.login.completed","requestId":"login","method":"chatgpt"}"#
        ])
        let factory = AuthorizationProcessFactory(processes: [status, login])
        let coordinator = makeCoordinator(factory: factory)

        coordinator.prepare(record: makeReviewRecord())
        try await waitForStage(.ready, coordinator: coordinator)

        #expect(factory.createdCount == 2)
        #expect(status.commandText.contains(#""type":"auth.status""#))
        #expect(login.commandText.contains(#""type":"auth.login""#))
    }

    @Test func failedBrowserLoginStaysInRecoverableConfirmation() async throws {
        let status = FakeAuthorizationProcess(lines: [
            #"{"type":"auth.status","requestId":"status","method":"signedOut"}"#
        ])
        let login = FakeAuthorizationProcess(lines: [
            #"{"type":"probe.failed","requestId":"login","category":"authentication","message":"ChatGPT sign-in did not complete."}"#
        ])
        let factory = AuthorizationProcessFactory(processes: [status, login])
        let coordinator = makeCoordinator(factory: factory)

        coordinator.prepare(record: makeReviewRecord())
        try await waitForStage(
            .failed(message: "ChatGPT sign-in did not complete."),
            coordinator: coordinator
        )

        #expect(coordinator.confirmation != nil)
    }

    @Test func browserLoginThatReturnsSignedOutShowsRetry() async throws {
        let status = FakeAuthorizationProcess(lines: [
            #"{"type":"auth.status","requestId":"status","method":"signedOut"}"#
        ])
        let login = FakeAuthorizationProcess(lines: [
            #"{"type":"auth.login.started","requestId":"login"}"#,
            #"{"type":"auth.status","requestId":"login","method":"signedOut"}"#
        ])
        let factory = AuthorizationProcessFactory(processes: [status, login])
        let coordinator = makeCoordinator(factory: factory)

        coordinator.prepare(record: makeReviewRecord())
        try await waitForStage(
            .failed(message: "ChatGPT sign-in did not complete."),
            coordinator: coordinator
        )

        #expect(factory.createdCount == 2)
    }

    @Test func confirmationKeepsTheSelectedOutputLanguage() {
        let coordinator = makeCoordinator(factory: AuthorizationProcessFactory(processes: []))

        coordinator.prepare(record: makeReviewRecord())
        coordinator.setOutputLanguage(.simplifiedChinese)

        #expect(coordinator.confirmation?.manifest.resolvedOutputLanguage == .simplifiedChinese)
    }

    private func makeCoordinator(
        factory: AuthorizationProcessFactory
    ) -> ReviewJobCoordinator {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewAuthTests-\(UUID().uuidString)", isDirectory: true)
        return ReviewJobCoordinator(
            store: ReviewJobStore(root: root),
            helperClient: ReviewHelperClient(processFactory: { try factory.make() })
        )
    }

    private func makeReviewRecord() -> SearchHistoryRecord {
        let work = makeWork(id: "https://openalex.org/W-auth")
        var ledger = UseLedger()
        ledger.mark(work)
        return makeRecord(
            query: "review authorization",
            works: [work],
            date: Date(),
            useLedger: ledger
        )
    }

    private func waitForStage(
        _ expected: ReviewAuthorizationStage,
        coordinator: ReviewJobCoordinator
    ) async throws {
        for _ in 0..<100 {
            if coordinator.confirmation?.authorizationStage == expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for authorization stage \(expected)")
    }
}

private final class AuthorizationProcessFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [FakeAuthorizationProcess]
    private var count = 0

    init(processes: [FakeAuthorizationProcess]) {
        self.processes = processes
    }

    var createdCount: Int {
        lock.withLock { count }
    }

    func make() throws -> ReviewHelperProcess {
        try lock.withLock {
            guard !processes.isEmpty else {
                throw ReviewHelperClientError.helperUnavailable
            }
            count += 1
            return processes.removeFirst()
        }
    }
}

private final class FakeAuthorizationProcess: ReviewHelperProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let chunks: [Data]
    private var writes: [Data] = []

    init(lines: [String]) {
        chunks = [Data((lines.joined(separator: "\n") + "\n").utf8)]
    }

    var commandText: String {
        lock.withLock { writes.map { String(decoding: $0, as: UTF8.self) }.joined() }
    }

    lazy var stdoutBytes = AsyncThrowingStream<Data, Error> { continuation in
        Task {
            for chunk in self.chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    lazy var stderrBytes = AsyncStream<Data> { continuation in
        continuation.finish()
    }

    func start() throws {}

    func write(_ data: Data) throws {
        lock.withLock { writes.append(data) }
    }

    func terminate() {}
    func waitForExit() async -> Int32 { 0 }
}
