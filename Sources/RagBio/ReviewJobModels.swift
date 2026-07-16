import Foundation

enum ReviewJobStatus: String, Codable, Equatable, Sendable {
    case confirming
    case running
    case paused
    case blocked
    case failed
    case completed
    case cancelled

    var isTerminal: Bool {
        [.failed, .completed, .cancelled].contains(self)
    }
}

enum ReviewJobStage: String, Codable, CaseIterable, Equatable, Sendable {
    case preparing
    case collecting
    case extracting
    case screening
    case synthesizing
    case workbook
    case manuscript
    case verifying

    var title: String {
        switch self {
        case .preparing: "Preparing review workspace"
        case .collecting: "Collecting paper sources"
        case .extracting: "Extracting study data"
        case .screening: "Checking study eligibility"
        case .synthesizing: "Synthesizing evidence"
        case .workbook: "Building Excel workbook"
        case .manuscript: "Building Word report"
        case .verifying: "Verifying deliverables"
        }
    }
}

struct ReviewJobArtifacts: Codable, Equatable, Sendable {
    var workbookPath: String
    var manuscriptPath: String
}

struct ReviewJob: Codable, Equatable, Identifiable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var version: Int
    var searchHistoryID: UUID
    var manifestID: UUID
    var query: String
    var status: ReviewJobStatus
    var stage: ReviewJobStage
    var stageDetail: String
    var completedPaperCount: Int
    var totalPaperCount: Int
    var helperThreadID: String?
    var warningMessages: [String]
    var blockMessage: String?
    var artifacts: ReviewJobArtifacts?
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
}

enum ReviewJobStoreError: Error, Equatable, LocalizedError {
    case jobNotFound
    case anotherJobIsRunning
    case immutableIdentityChanged

    var errorDescription: String? {
        switch self {
        case .jobNotFound: "The review task could not be found."
        case .anotherJobIsRunning: "Another review is already running."
        case .immutableIdentityChanged: "The saved review identity cannot be changed."
        }
    }
}
