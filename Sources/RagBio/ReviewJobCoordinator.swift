import AppKit
import Foundation

struct ReviewJobConfirmation: Identifiable, Equatable {
    var id: UUID { manifest.jobID }
    var manifest: ReviewInputManifest
}

@MainActor
final class ReviewJobCoordinator: ObservableObject {
    @Published private(set) var jobs: [ReviewJob] = []
    @Published var presentedJob: ReviewJob?
    @Published var confirmation: ReviewJobConfirmation?

    private let store: ReviewJobStore
    private let helperClient: ReviewHelperClient
    private var task: Task<Void, Never>?

    init(
        store: ReviewJobStore = ReviewJobStore(),
        helperClient: ReviewHelperClient = ReviewHelperClient()
    ) {
        self.store = store
        self.helperClient = helperClient
        Task { [weak self] in await self?.restore() }
    }

    deinit { task?.cancel() }

    func prepare(record: SearchHistoryRecord) {
        let jobID = UUID()
        confirmation = ReviewJobConfirmation(
            manifest: ReviewInputManifest.make(record: record, jobID: jobID)
        )
    }

    func dismissConfirmation() {
        confirmation = nil
    }

    func startConfirmedReview() {
        guard let manifest = confirmation?.manifest else { return }
        confirmation = nil
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
                await fail(jobID: manifest.jobID, message: error.localizedDescription)
            }
        }
    }

    func pause() {
        guard let job = presentedJob, job.status == .running else { return }
        task?.cancel()
        task = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                presentedJob = try await store.update(
                    id: job.id,
                    status: .paused,
                    detail: "Paused. Resume when you are ready."
                )
                await refreshJobs()
            } catch { }
        }
    }

    func resume() {
        guard let job = presentedJob, job.status == .paused else { return }
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
                await fail(jobID: job.id, message: error.localizedDescription)
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

    private func run(jobID: UUID) async throws {
        let manifest = try await store.manifest(jobID: jobID)
        var job = try await store.job(id: jobID)
        let papers = manifest.includedPapers
        let startIndex = min(job.completedPaperCount, papers.count)

        for index in startIndex..<papers.count {
            try Task.checkCancellation()
            let paper = papers[index]
            let stage: ReviewJobStage = index < papers.count / 3
                ? .collecting
                : (index < papers.count * 2 / 3 ? .extracting : .screening)
            job = try await store.update(
                id: jobID,
                status: .running,
                stage: stage,
                detail: paper.title,
                completedPaperCount: index
            )
            presentedJob = job
            try await Task.sleep(for: .milliseconds(110))
            job = try await store.update(id: jobID, completedPaperCount: index + 1)
            presentedJob = job
        }

        let workingDirectory = try await store.workingDirectory(jobID: jobID)
        let requestID = jobID.uuidString
        var generatedArtifacts: ReviewProbeArtifacts?
        for try await event in helperClient.events(for: .fixtureStart(
            requestID: requestID,
            workingDirectory: workingDirectory
        )) {
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
                throw ReviewJobRunError.helper("\(category.rawValue): \(message)")
            default:
                break
            }
            presentedJob = job
        }
        guard let generatedArtifacts else {
            throw ReviewJobRunError.helper("The Review Engine finished without deliverables.")
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

    private func fail(jobID: UUID, message: String) async {
        if let job = try? await store.update(
            id: jobID,
            status: .failed,
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
        case "workbook": .workbook
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
    case helper(String)

    var errorDescription: String? {
        switch self {
        case let .helper(message): message
        }
    }
}
