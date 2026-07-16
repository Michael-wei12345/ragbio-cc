import Foundation

enum ReviewHelperAuthMethod: String, Codable, Equatable, Sendable {
    case chatgpt
    case apiKey
    case signedOut
}

enum ReviewHelperFailureCategory: String, Codable, Equatable, Sendable {
    case authentication
    case allowance
    case network
    case runtime
    case `protocol`
}

enum ReviewHelperCommand: Encodable, Equatable, Sendable {
    case authStatus(requestID: String)
    case authLogin(requestID: String)
    case fixtureStart(requestID: String, workingDirectory: URL)
    case liveStart(requestID: String, workingDirectory: URL)
    case pause(requestID: String)
    case resume(requestID: String, threadID: String, workingDirectory: URL)
    case reviewStart(requestID: String, workingDirectory: URL)
    case reviewPause(requestID: String)
    case reviewResume(requestID: String, threadID: String, workingDirectory: URL)

    var requestID: String {
        switch self {
        case let .authStatus(requestID), let .authLogin(requestID), let .pause(requestID),
             let .reviewPause(requestID):
            requestID
        case let .fixtureStart(requestID, _), let .liveStart(requestID, _),
             let .reviewStart(requestID, _):
            requestID
        case let .resume(requestID, _, _), let .reviewResume(requestID, _, _):
            requestID
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, requestId, mode, workingDirectory, threadId
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestID, forKey: .requestId)
        switch self {
        case .authStatus:
            try values.encode("auth.status", forKey: .type)
        case .authLogin:
            try values.encode("auth.login", forKey: .type)
        case let .fixtureStart(_, workingDirectory):
            try values.encode("probe.start", forKey: .type)
            try values.encode("fixture", forKey: .mode)
            try values.encode(workingDirectory.path, forKey: .workingDirectory)
        case let .liveStart(_, workingDirectory):
            try values.encode("probe.start", forKey: .type)
            try values.encode("live", forKey: .mode)
            try values.encode(workingDirectory.path, forKey: .workingDirectory)
        case .pause:
            try values.encode("probe.pause", forKey: .type)
        case let .resume(_, threadID, workingDirectory):
            try values.encode("probe.resume", forKey: .type)
            try values.encode(threadID, forKey: .threadId)
            try values.encode(workingDirectory.path, forKey: .workingDirectory)
        case let .reviewStart(_, workingDirectory):
            try values.encode("review.start", forKey: .type)
            try values.encode(workingDirectory.path, forKey: .workingDirectory)
        case .reviewPause:
            try values.encode("review.pause", forKey: .type)
        case let .reviewResume(_, threadID, workingDirectory):
            try values.encode("review.resume", forKey: .type)
            try values.encode(threadID, forKey: .threadId)
            try values.encode(workingDirectory.path, forKey: .workingDirectory)
        }
    }

    func jsonLine() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}

enum ReviewHelperEvent: Equatable, Sendable, Decodable {
    case authStatus(requestID: String, method: ReviewHelperAuthMethod)
    case authLoginStarted(requestID: String)
    case authLoginCompleted(requestID: String)
    case started(requestID: String, threadID: String)
    case stage(requestID: String, stage: String, detail: String)
    case artifacts(requestID: String, workbookURL: URL, manuscriptURL: URL)
    case paused(requestID: String, threadID: String)
    case completed(requestID: String, threadID: String)
    case failed(
        requestID: String,
        category: ReviewHelperFailureCategory,
        message: String
    )

    var isTerminal: Bool {
        switch self {
        case .authStatus, .authLoginCompleted, .paused, .completed, .failed:
            true
        case .authLoginStarted, .started, .stage, .artifacts:
            false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, requestId, method, threadId, stage, detail
        case workbookPath, manuscriptPath, category, message
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let type = try values.decode(String.self, forKey: .type)
        let requestID = try values.decode(String.self, forKey: .requestId)
        switch type {
        case "auth.status":
            self = .authStatus(
                requestID: requestID,
                method: try values.decode(ReviewHelperAuthMethod.self, forKey: .method)
            )
        case "auth.login.started":
            self = .authLoginStarted(requestID: requestID)
        case "auth.login.completed":
            self = .authLoginCompleted(requestID: requestID)
        case "probe.started":
            self = .started(
                requestID: requestID,
                threadID: try values.decode(String.self, forKey: .threadId)
            )
        case "probe.stage":
            self = .stage(
                requestID: requestID,
                stage: try values.decode(String.self, forKey: .stage),
                detail: try values.decode(String.self, forKey: .detail)
            )
        case "probe.artifacts":
            self = .artifacts(
                requestID: requestID,
                workbookURL: URL(
                    fileURLWithPath: try values.decode(String.self, forKey: .workbookPath)
                ),
                manuscriptURL: URL(
                    fileURLWithPath: try values.decode(String.self, forKey: .manuscriptPath)
                )
            )
        case "probe.paused":
            self = .paused(
                requestID: requestID,
                threadID: try values.decode(String.self, forKey: .threadId)
            )
        case "probe.completed":
            self = .completed(
                requestID: requestID,
                threadID: try values.decode(String.self, forKey: .threadId)
            )
        case "probe.failed":
            self = .failed(
                requestID: requestID,
                category: try values.decode(
                    ReviewHelperFailureCategory.self,
                    forKey: .category
                ),
                message: try values.decode(String.self, forKey: .message)
            )
        default:
            throw ReviewHelperClientError.unsupportedEvent
        }
    }
}

enum ReviewHelperClientError: Error, Equatable, CustomStringConvertible {
    case helperUnavailable
    case noActiveProcess
    case malformedEvent
    case unsupportedEvent
    case lineTooLong
    case processExited

    var description: String {
        switch self {
        case .helperUnavailable: "The local Review Engine is unavailable."
        case .noActiveProcess: "No Review Engine task is running."
        case .malformedEvent: "The Review Engine returned an invalid event."
        case .unsupportedEvent: "The Review Engine returned an unsupported event."
        case .lineTooLong: "The Review Engine returned an oversized event."
        case .processExited: "The local Review Engine stopped unexpectedly."
        }
    }
}
