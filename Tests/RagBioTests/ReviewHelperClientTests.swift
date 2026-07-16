import Foundation
import Testing
@testable import RagBio

@Suite struct ReviewHelperClientTests {
    @Test func decodesEventSplitAcrossChunks() async throws {
        let process = FakeReviewHelperProcess(stdoutChunks: [
            Data(#"{"type":"probe.started","requestId":"r1","th"#.utf8),
            Data("readId\":\"t1\"}\n".utf8),
            Data(#"{"type":"probe.completed","requestId":"r1","threadId":"t1"}"#.utf8)
                + Data("\n".utf8)
        ])
        let client = ReviewHelperClient(processFactory: { process })

        let events = try await collect(client.events(for: .fixtureStart(
            requestID: "r1",
            workingDirectory: URL(fileURLWithPath: "/tmp/probe")
        )))

        #expect(events == [
            .started(requestID: "r1", threadID: "t1"),
            .completed(requestID: "r1", threadID: "t1")
        ])
    }

    @Test func decodesMultipleEventsInOneChunk() async throws {
        let lines = """
        {"type":"probe.stage","requestId":"r1","stage":"prepare","detail":"Preparing"}
        {"type":"probe.paused","requestId":"r1","threadId":"t1"}

        """
        let process = FakeReviewHelperProcess(stdoutChunks: [Data(lines.utf8)])
        let client = ReviewHelperClient(processFactory: { process })

        let events = try await collect(client.events(for: .fixtureStart(
            requestID: "r1",
            workingDirectory: URL(fileURLWithPath: "/tmp/probe")
        )))

        #expect(events == [
            .stage(requestID: "r1", stage: "prepare", detail: "Preparing"),
            .paused(requestID: "r1", threadID: "t1")
        ])
    }

    @Test func malformedJSONFailsWithoutLeakingTheLine() async {
        let process = FakeReviewHelperProcess(stdoutChunks: [
            Data("{private malformed json}\n".utf8)
        ])
        let client = ReviewHelperClient(processFactory: { process })

        do {
            _ = try await collect(client.events(for: .authStatus(requestID: "r1")))
            Issue.record("Expected malformed JSON to fail")
        } catch {
            #expect(String(describing: error).contains("private") == false)
            #expect(error as? ReviewHelperClientError == .malformedEvent)
        }
    }

    @Test func nonzeroExitUsesSafeErrorWithoutStderr() async {
        let process = FakeReviewHelperProcess(
            stdoutChunks: [],
            stderrChunks: [Data("private runtime diagnostic".utf8)],
            exitStatus: 9
        )
        let client = ReviewHelperClient(processFactory: { process })

        do {
            _ = try await collect(client.events(for: .authStatus(requestID: "r1")))
            Issue.record("Expected nonzero exit to fail")
        } catch {
            #expect(String(describing: error).contains("private") == false)
            #expect(error as? ReviewHelperClientError == .processExited)
        }
    }

    @Test func cancellingTheEventTaskTerminatesTheProcess() async {
        let process = FakeReviewHelperProcess(stdoutChunks: [], keepOpen: true)
        let client = ReviewHelperClient(processFactory: { process })
        let task = Task {
            for try await _ in client.events(for: .authStatus(requestID: "r1")) {}
        }

        await Task.yield()
        task.cancel()
        _ = try? await task.value

        for _ in 0..<20 where !process.wasTerminated {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(process.wasTerminated)
    }

    @Test func pauseWritesToTheActiveHelperProcess() async throws {
        let process = FakeReviewHelperProcess(stdoutChunks: [], keepOpen: true)
        let client = ReviewHelperClient(processFactory: { process })
        let task = Task {
            for try await _ in client.events(for: .liveStart(
                requestID: "r1",
                workingDirectory: URL(fileURLWithPath: "/tmp/probe")
            )) {}
        }

        for _ in 0..<20 where process.writtenData.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await client.pause(requestID: "r1")

        let lines = process.writtenData.compactMap { String(data: $0, encoding: .utf8) }
        #expect(lines.count == 2)
        #expect(lines[0].contains(#""type":"probe.start""#))
        #expect(lines[1].contains(#""type":"probe.pause""#))
        task.cancel()
        _ = try? await task.value
    }
}

private func collect(
    _ stream: AsyncThrowingStream<ReviewHelperEvent, Error>
) async throws -> [ReviewHelperEvent] {
    var events: [ReviewHelperEvent] = []
    for try await event in stream { events.append(event) }
    return events
}

private final class FakeReviewHelperProcess: ReviewHelperProcess, @unchecked Sendable {
    private let lock = NSLock()
    private let stdoutChunks: [Data]
    private let stderrChunks: [Data]
    private let exitStatus: Int32
    private let keepOpen: Bool
    private var terminated = false
    private var writes: [Data] = []

    init(
        stdoutChunks: [Data],
        stderrChunks: [Data] = [],
        exitStatus: Int32 = 0,
        keepOpen: Bool = false
    ) {
        self.stdoutChunks = stdoutChunks
        self.stderrChunks = stderrChunks
        self.exitStatus = exitStatus
        self.keepOpen = keepOpen
    }

    var wasTerminated: Bool { lock.withLock { terminated } }
    var writtenData: [Data] { lock.withLock { writes } }

    lazy var stdoutBytes = AsyncThrowingStream<Data, Error> { continuation in
        Task {
            for chunk in self.stdoutChunks { continuation.yield(chunk) }
            if !self.keepOpen { continuation.finish() }
        }
    }

    lazy var stderrBytes = AsyncStream<Data> { continuation in
        Task {
            for chunk in self.stderrChunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    func start() throws {}

    func write(_ data: Data) throws {
        lock.withLock { writes.append(data) }
    }

    func terminate() {
        lock.withLock { terminated = true }
    }

    func waitForExit() async -> Int32 { exitStatus }
}
