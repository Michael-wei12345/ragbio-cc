import Foundation

final class ReviewHelperClient: @unchecked Sendable {
    typealias ProcessFactory = @Sendable () throws -> ReviewHelperProcess

    private static let maximumLineBytes = 1_048_576
    private let processFactory: ProcessFactory
    private let lock = NSLock()
    private var activeProcess: ReviewHelperProcess?

    init(processFactory: @escaping ProcessFactory = { try SystemReviewHelperProcess() }) {
        self.processFactory = processFactory
    }

    func events(
        for command: ReviewHelperCommand
    ) -> AsyncThrowingStream<ReviewHelperEvent, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    let process = try processFactory()
                    setActive(process)
                    try Task.checkCancellation()
                    try process.start()
                    try process.write(command.jsonLine())
                    let stderrDrain = Task {
                        var capturedBytes = 0
                        for await chunk in process.stderrBytes {
                            capturedBytes = min(capturedBytes + chunk.count, 8_192)
                        }
                    }

                    var buffer = Data()
                    var reachedTerminalEvent = false
                    for try await chunk in process.stdoutBytes {
                        try Task.checkCancellation()
                        buffer.append(chunk)
                        if buffer.count > Self.maximumLineBytes,
                           !buffer.contains(0x0A) {
                            throw ReviewHelperClientError.lineTooLong
                        }
                        for event in try Self.decodeAvailableEvents(from: &buffer) {
                            continuation.yield(event)
                            if event.isTerminal {
                                reachedTerminalEvent = true
                                break
                            }
                        }
                        if reachedTerminalEvent { break }
                    }

                    if reachedTerminalEvent {
                        process.terminate()
                        stderrDrain.cancel()
                        clearActive(process)
                        continuation.finish()
                        return
                    }

                    let status = await process.waitForExit()
                    stderrDrain.cancel()
                    clearActive(process)
                    if status != 0 { throw ReviewHelperClientError.processExited }
                    if !buffer.allSatisfy({ $0 == 0x0A || $0 == 0x0D || $0 == 0x20 }) {
                        throw ReviewHelperClientError.malformedEvent
                    }
                    throw ReviewHelperClientError.processExited
                } catch is CancellationError {
                    terminateActiveProcess()
                    continuation.finish()
                } catch let error as ReviewHelperClientError {
                    terminateActiveProcess()
                    continuation.finish(throwing: error)
                } catch {
                    terminateActiveProcess()
                    continuation.finish(throwing: ReviewHelperClientError.processExited)
                }
            }
            continuation.onTermination = { [weak self] _ in
                producer.cancel()
                self?.terminateActiveProcess()
            }
        }
    }

    func pause(requestID: String) async throws {
        guard let process = lock.withLock({ activeProcess }) else {
            throw ReviewHelperClientError.noActiveProcess
        }
        try process.write(ReviewHelperCommand.pause(requestID: requestID).jsonLine())
    }

    func pauseReview(requestID: String) async throws {
        guard let process = lock.withLock({ activeProcess }) else {
            throw ReviewHelperClientError.noActiveProcess
        }
        try process.write(ReviewHelperCommand.reviewPause(requestID: requestID).jsonLine())
    }

    private static func decodeAvailableEvents(
        from buffer: inout Data
    ) throws -> [ReviewHelperEvent] {
        var events: [ReviewHelperEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if line.last == 0x0D { line.removeLast() }
            if line.isEmpty { continue }
            guard line.count <= maximumLineBytes, String(data: line, encoding: .utf8) != nil else {
                throw ReviewHelperClientError.malformedEvent
            }
            do {
                events.append(try JSONDecoder().decode(ReviewHelperEvent.self, from: line))
            } catch let error as ReviewHelperClientError {
                throw error
            } catch {
                throw ReviewHelperClientError.malformedEvent
            }
        }
        return events
    }

    private func setActive(_ process: ReviewHelperProcess) {
        lock.withLock { activeProcess = process }
    }

    private func clearActive(_ process: ReviewHelperProcess) {
        lock.withLock {
            if activeProcess === process { activeProcess = nil }
        }
    }

    private func terminateActiveProcess() {
        let process = lock.withLock { () -> ReviewHelperProcess? in
            defer { activeProcess = nil }
            return activeProcess
        }
        process?.terminate()
    }
}
