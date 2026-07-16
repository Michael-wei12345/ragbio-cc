import AppKit
import Foundation

struct ReviewProbeArtifacts: Equatable, Sendable {
    let workbookURL: URL
    let manuscriptURL: URL
}

struct ReviewProbeCheckpoint: Codable, Equatable, Sendable {
    var requestID: String
    var threadID: String
    var workingDirectory: URL
    var status: Status

    enum Status: String, Codable, Equatable, Sendable {
        case running
        case paused
    }
}

@MainActor
final class ReviewConnectionProbe: ObservableObject {
    enum State: Equatable {
        case idle
        case running(stage: String, detail: String)
        case paused(threadID: String)
        case blocked(category: ReviewHelperFailureCategory, message: String)
        case completed(artifacts: ReviewProbeArtifacts)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var authMethod: ReviewHelperAuthMethod = .signedOut

    private let client: ReviewHelperClient
    private let outputRoot: URL
    private let checkpointURL: URL
    private var task: Task<Void, Never>?
    private var requestID: String?
    private var threadID: String?
    private var workingDirectory: URL?
    private var artifacts: ReviewProbeArtifacts?

    private(set) var resumeCheckpoint: ReviewProbeCheckpoint?

    init(
        client: ReviewHelperClient = ReviewHelperClient(),
        outputRoot: URL? = nil,
        checkpointURL: URL? = nil
    ) {
        self.client = client
        let support = Self.defaultSupportDirectory()
        self.outputRoot = outputRoot ?? support.appendingPathComponent("Runs", isDirectory: true)
        self.checkpointURL = checkpointURL ?? support.appendingPathComponent("checkpoint.json")
        restoreCheckpoint()
    }

    deinit { task?.cancel() }

    func refreshAuthStatus() {
        run(.authStatus(requestID: UUID().uuidString))
    }

    func connectChatGPT() {
        run(.authLogin(requestID: UUID().uuidString))
    }

    func startFixture() {
        start(mode: .fixture)
    }

    func startLive() {
        start(mode: .live)
    }

    func pause() {
        guard let requestID else { return }
        Task {
            do {
                try await client.pause(requestID: requestID)
            } catch {
                state = .blocked(
                    category: .runtime,
                    message: "The Review Engine could not pause the connection test."
                )
            }
        }
    }

    func resume() {
        guard let checkpoint = resumeCheckpoint else { return }
        requestID = UUID().uuidString
        threadID = checkpoint.threadID
        workingDirectory = checkpoint.workingDirectory
        state = .running(stage: "resume", detail: "Resuming the Codex connection test")
        run(.resume(
            requestID: requestID!,
            threadID: checkpoint.threadID,
            workingDirectory: checkpoint.workingDirectory
        ))
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
        requestID = nil
        threadID = nil
        workingDirectory = nil
        artifacts = nil
        resumeCheckpoint = nil
        deleteCheckpoint()
    }

    func openWorkbook() {
        guard case let .completed(artifacts) = state else { return }
        NSWorkspace.shared.open(artifacts.workbookURL)
    }

    func openManuscript() {
        guard case let .completed(artifacts) = state else { return }
        NSWorkspace.shared.open(artifacts.manuscriptURL)
    }

    func showInFinder() {
        guard case let .completed(artifacts) = state else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            artifacts.workbookURL,
            artifacts.manuscriptURL
        ])
    }

    func apply(_ event: ReviewHelperEvent) {
        switch event {
        case let .authStatus(_, method):
            authMethod = method
        case .authLoginStarted:
            state = .running(stage: "sign-in", detail: "Waiting for ChatGPT sign-in")
        case .authLoginCompleted:
            authMethod = .chatgpt
            state = .idle
        case let .started(requestID, threadID):
            self.requestID = requestID
            self.threadID = threadID
            state = .running(stage: "connect", detail: "Connected to the local Codex runtime")
            saveCheckpoint(status: .running)
        case let .stage(_, stage, detail):
            state = .running(stage: stage, detail: detail)
            saveCheckpoint(status: .running)
        case let .artifacts(_, workbookURL, manuscriptURL):
            artifacts = ReviewProbeArtifacts(
                workbookURL: workbookURL,
                manuscriptURL: manuscriptURL
            )
        case let .paused(_, threadID):
            self.threadID = threadID
            state = .paused(threadID: threadID)
            saveCheckpoint(status: .paused)
        case .completed:
            if let artifacts {
                state = .completed(artifacts: artifacts)
            } else {
                state = .blocked(
                    category: .runtime,
                    message: "The connection test completed without its fixture files."
                )
            }
            resumeCheckpoint = nil
            deleteCheckpoint()
        case let .failed(_, category, message):
            state = .blocked(category: category, message: message)
        }
    }

    private enum ProbeMode { case fixture, live }

    private func start(mode: ProbeMode) {
        do {
            task?.cancel()
            let requestID = UUID().uuidString
            let directory = outputRoot.appendingPathComponent(requestID, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            self.requestID = requestID
            threadID = nil
            workingDirectory = directory
            artifacts = nil
            resumeCheckpoint = nil
            state = .running(stage: "prepare", detail: "Starting the connection test")
            let command: ReviewHelperCommand = mode == .fixture
                ? .fixtureStart(requestID: requestID, workingDirectory: directory)
                : .liveStart(requestID: requestID, workingDirectory: directory)
            run(command)
        } catch {
            state = .blocked(
                category: .runtime,
                message: "RagBio could not create the Review Engine test workspace."
            )
        }
    }

    private func run(_ command: ReviewHelperCommand) {
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in client.events(for: command) {
                    apply(event)
                }
            } catch {
                state = .blocked(
                    category: .runtime,
                    message: String(describing: error)
                )
            }
        }
    }

    private func saveCheckpoint(status: ReviewProbeCheckpoint.Status) {
        guard let requestID, let threadID, let workingDirectory else { return }
        let checkpoint = ReviewProbeCheckpoint(
            requestID: requestID,
            threadID: threadID,
            workingDirectory: workingDirectory,
            status: status
        )
        do {
            try FileManager.default.createDirectory(
                at: checkpointURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(checkpoint).write(to: checkpointURL, options: .atomic)
            resumeCheckpoint = checkpoint
        } catch {
            state = .blocked(
                category: .runtime,
                message: "RagBio could not save the Review Engine checkpoint."
            )
        }
    }

    private func restoreCheckpoint() {
        guard
            let data = try? Data(contentsOf: checkpointURL),
            let checkpoint = try? JSONDecoder().decode(ReviewProbeCheckpoint.self, from: data)
        else { return }
        resumeCheckpoint = checkpoint
        requestID = checkpoint.requestID
        threadID = checkpoint.threadID
        workingDirectory = checkpoint.workingDirectory
        state = .paused(threadID: checkpoint.threadID)
    }

    private func deleteCheckpoint() {
        try? FileManager.default.removeItem(at: checkpointURL)
    }

    private static func defaultSupportDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("RagBio", isDirectory: true)
            .appendingPathComponent("ReviewProbe", isDirectory: true)
    }
}
