import AppKit
import Foundation

struct ReviewJobConfirmation: Identifiable, Equatable {
    var id: UUID { manifest.jobID }
    var manifest: ReviewInputManifest
    var authorizationStage: ReviewAuthorizationStage = .checking
}

enum ReviewAuthorizationStage: Equatable {
    case checking
    case signingIn
    case ready
    case failed(message: String)

    var isBusy: Bool {
        self == .checking || self == .signingIn
    }
}

@MainActor
final class ReviewJobCoordinator: ObservableObject {
    @Published private(set) var jobs: [ReviewJob] = []
    @Published var presentedJob: ReviewJob?
    @Published var confirmation: ReviewJobConfirmation?

    private let store: ReviewJobStore
    private let helperClient: ReviewHelperClient
    private var task: Task<Void, Never>?
    private var authorizationTask: Task<Void, Never>?

    init(
        store: ReviewJobStore = ReviewJobStore(),
        helperClient: ReviewHelperClient = ReviewHelperClient()
    ) {
        self.store = store
        self.helperClient = helperClient
        Task { [weak self] in await self?.restore() }
    }

    deinit {
        task?.cancel()
        authorizationTask?.cancel()
    }

    func prepare(record: SearchHistoryRecord) {
        authorizationTask?.cancel()
        let jobID = UUID()
        confirmation = ReviewJobConfirmation(
            manifest: ReviewInputManifest.make(record: record, jobID: jobID)
        )
        beginAuthorization(for: jobID)
    }

    func retryAuthorization() {
        guard let confirmation else { return }
        setAuthorizationStage(.checking, for: confirmation.id)
        beginAuthorization(for: confirmation.id)
    }

    func dismissConfirmation() {
        authorizationTask?.cancel()
        authorizationTask = nil
        self.confirmation = nil
    }

    func startConfirmedReview() {
        guard let confirmation,
              confirmation.authorizationStage == .ready else { return }
        let manifest = confirmation.manifest
        authorizationTask?.cancel()
        authorizationTask = nil
        self.confirmation = nil
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var job = try await store.create(manifest: manifest)
                job = try await store.update(
                    id: job.id,
                    status: .running,
                    stage: .preparing,
                    detail: "Saving the fixed input manifest"
                )
                presentedJob = job
                await refreshJobs()
                try await run(jobID: job.id)
            } catch is CancellationError {
                return
            } catch {
                await fail(jobID: manifest.jobID, error: error)
            }
        }
    }

    func pause() {
        guard let job = presentedJob, job.status == .running else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await helperClient.pauseReview(requestID: job.id.uuidString)
            } catch {
                task?.cancel()
                task = nil
                presentedJob = try? await store.update(
                    id: job.id,
                    status: .paused,
                    detail: "Paused locally. Resume when you are ready."
                )
                await refreshJobs()
            }
        }
    }

    func resume() {
        guard let job = presentedJob,
              [.paused, .blocked, .failed].contains(job.status) else { return }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                presentedJob = try await store.update(
                    id: job.id,
                    status: .running,
                    detail: "Resuming from the saved checkpoint"
                )
                await refreshJobs()
                try await run(jobID: job.id)
            } catch is CancellationError {
                return
            } catch {
                await fail(jobID: job.id, error: error)
            }
        }
    }

    func cancel() {
        guard let job = presentedJob, !job.status.isTerminal else { return }
        task?.cancel()
        task = nil
        Task { [weak self] in
            guard let self else { return }
            presentedJob = try? await store.update(
                id: job.id,
                status: .cancelled,
                detail: "Review cancelled. The saved input manifest was kept."
            )
            await refreshJobs()
        }
    }

    func show(_ job: ReviewJob) {
        presentedJob = job
    }

    func closeWorkspace() {
        presentedJob = nil
    }

    func openWorkbook() {
        guard let url = artifactURL(\.workbookPath) else { return }
        NSWorkspace.shared.open(url)
    }

    func openManuscript() {
        guard let url = artifactURL(\.manuscriptPath) else { return }
        NSWorkspace.shared.open(url)
    }

    func showInFinder() {
        guard let job = presentedJob, let artifacts = job.artifacts else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            URL(fileURLWithPath: artifacts.workbookPath),
            URL(fileURLWithPath: artifacts.manuscriptPath)
        ])
    }

    private func restore() async {
        do {
            jobs = try await store.bootstrap()
            if let active = jobs.first(where: { $0.status == .paused }) {
                presentedJob = active
            }
        } catch { }
    }

    private func refreshJobs() async {
        jobs = (try? await store.jobs()) ?? jobs
    }

    private func beginAuthorization(for confirmationID: UUID) {
        authorizationTask?.cancel()
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let method = try await currentAuthMethod()
                try Task.checkCancellation()
                guard method != .chatgpt else {
                    setAuthorizationStage(.ready, for: confirmationID)
                    return
                }

                setAuthorizationStage(.signingIn, for: confirmationID)
                try await signInToChatGPT()
                try Task.checkCancellation()
                setAuthorizationStage(.ready, for: confirmationID)
            } catch is CancellationError {
                return
            } catch {
                setAuthorizationStage(
                    .failed(message: authorizationMessage(for: error)),
                    for: confirmationID
                )
            }
        }
    }

    private func currentAuthMethod() async throws -> ReviewHelperAuthMethod {
        for try await event in helperClient.events(for: .authStatus(
            requestID: UUID().uuidString
        )) {
            switch event {
            case let .authStatus(_, method):
                return method
            case let .failed(_, category, message):
                throw ReviewJobRunError.helper(category: category, message: message)
            default:
                continue
            }
        }
        throw ReviewHelperClientError.processExited
    }

    private func signInToChatGPT() async throws {
        for try await event in helperClient.events(for: .authLogin(
            requestID: UUID().uuidString
        )) {
            switch event {
            case .authLoginCompleted:
                return
            case .authStatus:
                throw ReviewJobRunError.helper(
                    category: .authentication,
                    message: "ChatGPT sign-in did not complete."
                )
            case let .failed(_, category, message):
                throw ReviewJobRunError.helper(category: category, message: message)
            default:
                continue
            }
        }
        throw ReviewHelperClientError.processExited
    }

    private func setAuthorizationStage(
        _ stage: ReviewAuthorizationStage,
        for confirmationID: UUID
    ) {
        guard var current = confirmation, current.id == confirmationID else { return }
        current.authorizationStage = stage
        confirmation = current
    }

    private func authorizationMessage(for error: Error) -> String {
        if case let ReviewJobRunError.helper(_, message) = error {
            return message
        }
        if let helperError = error as? ReviewHelperClientError {
            return helperError.description
        }
        return "ChatGPT sign-in could not be completed. Try again."
    }

    private func run(jobID: UUID) async throws {
        let manifest = try await store.manifest(jobID: jobID)
        var job = try await store.job(id: jobID)
        let papers = manifest.includedPapers
        let workingDirectory = try await store.workingDirectory(jobID: jobID)
        try writeEngineManifest(manifest, to: workingDirectory)
        let requestID = jobID.uuidString
        var generatedArtifacts: ReviewProbeArtifacts?
        var wasPaused = false
        let command: ReviewHelperCommand
        if let threadID = job.helperThreadID {
            command = .reviewResume(
                requestID: requestID,
                threadID: threadID,
                workingDirectory: workingDirectory
            )
        } else {
            command = .reviewStart(requestID: requestID, workingDirectory: workingDirectory)
        }
        job = try await store.update(
            id: jobID,
            status: .running,
            stage: .collecting,
            detail: "Review Engine is reading the selected paper sources"
        )
        presentedJob = job
        for try await event in helperClient.events(for: command) {
            try Task.checkCancellation()
            switch event {
            case let .started(_, threadID):
                job = try await store.update(
                    id: jobID,
                    status: .running,
                    stage: .synthesizing,
                    detail: "Preparing deterministic Review Engine deliverables",
                    helperThreadID: threadID
                )
            case let .stage(_, stage, detail):
                job = try await store.update(
                    id: jobID,
                    stage: mapStage(stage),
                    detail: detail
                )
            case let .artifacts(_, workbookURL, manuscriptURL):
                generatedArtifacts = ReviewProbeArtifacts(
                    workbookURL: workbookURL,
                    manuscriptURL: manuscriptURL
                )
            case let .failed(_, category, message):
                throw ReviewJobRunError.helper(category: category, message: message)
            case let .paused(_, threadID):
                wasPaused = true
                job = try await store.update(
                    id: jobID,
                    status: .paused,
                    detail: "Paused. Resume when you are ready.",
                    helperThreadID: threadID
                )
            default:
                break
            }
            presentedJob = job
        }
        if wasPaused {
            await refreshJobs()
            return
        }
        guard let generatedArtifacts else {
            throw ReviewJobRunError.helper(
                category: .runtime,
                message: "The Review Engine finished without deliverables."
            )
        }
        let artifacts = try await installArtifacts(generatedArtifacts, jobID: jobID)
        job = try await store.update(
            id: jobID,
            status: .completed,
            stage: .verifying,
            detail: "Excel and Word deliverables are ready.",
            completedPaperCount: papers.count,
            warnings: manifest.missingURLCount == 0
                ? []
                : ["\(manifest.missingURLCount) Use paper(s) had no usable URL."],
            artifacts: artifacts
        )
        presentedJob = job
        await refreshJobs()
    }

    private func writeEngineManifest(
        _ manifest: ReviewInputManifest,
        to workingDirectory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = workingDirectory.appendingPathComponent("review-manifest.json")
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    private func installArtifacts(
        _ source: ReviewProbeArtifacts,
        jobID: UUID
    ) async throws -> ReviewJobArtifacts {
        let output = try await store.outputDirectory(jobID: jobID)
        let workbook = output.appendingPathComponent("RagBio Systematic Review.xlsx")
        let manuscript = output.appendingPathComponent("RagBio Systematic Review.docx")
        try replace(source.workbookURL, with: workbook)
        try replace(source.manuscriptURL, with: manuscript)
        return ReviewJobArtifacts(
            workbookPath: workbook.path,
            manuscriptPath: manuscript.path
        )
    }

    private func replace(_ source: URL, with destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func fail(jobID: UUID, error: Error) async {
        let status: ReviewJobStatus
        let message: String
        if case let ReviewJobRunError.helper(category, safeMessage) = error {
            status = [.authentication, .allowance, .network].contains(category)
                ? .blocked
                : .failed
            message = safeMessage
        } else {
            status = .failed
            message = error.localizedDescription
        }
        if let job = try? await store.update(
            id: jobID,
            status: status,
            detail: "Review generation stopped.",
            blockMessage: message
        ) {
            presentedJob = job
        }
        await refreshJobs()
    }

    private func mapStage(_ value: String) -> ReviewJobStage {
        switch value {
        case "extract": .extracting
        case "generate", "workbook": .workbook
        case "manuscript": .manuscript
        case "verify": .verifying
        default: .synthesizing
        }
    }

    private func artifactURL(_ keyPath: KeyPath<ReviewJobArtifacts, String>) -> URL? {
        guard let artifacts = presentedJob?.artifacts else { return nil }
        return URL(fileURLWithPath: artifacts[keyPath: keyPath])
    }
}

private enum ReviewJobRunError: Error, LocalizedError {
    case helper(category: ReviewHelperFailureCategory, message: String)

    var errorDescription: String? {
        switch self {
        case let .helper(_, message): message
        }
    }
}
