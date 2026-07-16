import Foundation
import Testing
@testable import RagBio

@MainActor
@Suite struct ReviewConnectionProbeTests {
    @Test func orderedEventsRetainArtifactsAfterCompletion() throws {
        let root = try makeTemporaryDirectory()
        let probe = ReviewConnectionProbe(
            outputRoot: root.appendingPathComponent("runs"),
            checkpointURL: root.appendingPathComponent("checkpoint.json")
        )
        let workbook = root.appendingPathComponent("Review.xlsx")
        let manuscript = root.appendingPathComponent("Review.docx")

        probe.apply(.started(requestID: "r1", threadID: "t1"))
        probe.apply(.stage(requestID: "r1", stage: "extract", detail: "Reading papers"))
        probe.apply(.artifacts(
            requestID: "r1",
            workbookURL: workbook,
            manuscriptURL: manuscript
        ))
        probe.apply(.completed(requestID: "r1", threadID: "t1"))

        #expect(probe.state == .completed(artifacts: ReviewProbeArtifacts(
            workbookURL: workbook,
            manuscriptURL: manuscript
        )))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "checkpoint.json"
        ).path))
    }

    @Test func authenticationAndAllowanceFailuresAreRecoverableBlocks() throws {
        let root = try makeTemporaryDirectory()
        let probe = ReviewConnectionProbe(
            outputRoot: root,
            checkpointURL: root.appendingPathComponent("checkpoint.json")
        )

        probe.apply(.failed(
            requestID: "r1",
            category: .authentication,
            message: "Sign in to ChatGPT."
        ))
        #expect(probe.state == .blocked(
            category: .authentication,
            message: "Sign in to ChatGPT."
        ))

        probe.apply(.failed(
            requestID: "r1",
            category: .allowance,
            message: "Try again later."
        ))
        #expect(probe.state == .blocked(
            category: .allowance,
            message: "Try again later."
        ))
    }

    @Test func pausedCheckpointRestoresWithoutAutomaticallyRunning() throws {
        let root = try makeTemporaryDirectory()
        let checkpointURL = root.appendingPathComponent("checkpoint.json")
        let workingDirectory = root.appendingPathComponent("run")
        let checkpoint = ReviewProbeCheckpoint(
            requestID: "r1",
            threadID: "t1",
            workingDirectory: workingDirectory,
            status: .paused
        )
        try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)

        let restored = ReviewConnectionProbe(
            outputRoot: root,
            checkpointURL: checkpointURL
        )

        #expect(restored.state == .paused(threadID: "t1"))
        #expect(restored.resumeCheckpoint == checkpoint)
    }
}
