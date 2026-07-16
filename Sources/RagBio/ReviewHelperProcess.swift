import Foundation

protocol ReviewHelperProcess: AnyObject, Sendable {
    var stdoutBytes: AsyncThrowingStream<Data, Error> { get }
    var stderrBytes: AsyncStream<Data> { get }
    func start() throws
    func write(_ data: Data) throws
    func terminate()
    func waitForExit() async -> Int32
}

struct ReviewHelperLaunchConfiguration: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) throws -> ReviewHelperLaunchConfiguration {
        let developmentNode = environment["RAGBIO_REVIEW_HELPER_NODE"]
        let developmentScript = environment["RAGBIO_REVIEW_HELPER_SCRIPT"]
        if developmentNode != nil || developmentScript != nil {
            guard
                let developmentNode,
                let developmentScript,
                fileManager.isExecutableFile(atPath: developmentNode),
                fileManager.fileExists(atPath: developmentScript)
            else { throw ReviewHelperClientError.helperUnavailable }
            return ReviewHelperLaunchConfiguration(
                executableURL: URL(fileURLWithPath: developmentNode),
                arguments: [developmentScript]
            )
        }

        let runtime = bundleURL
            .appendingPathComponent("Contents/Resources/ReviewRuntime", isDirectory: true)
        let node = runtime.appendingPathComponent("node")
        let script = runtime.appendingPathComponent("helper/dist/main.js")
        guard
            fileManager.isExecutableFile(atPath: node.path),
            fileManager.fileExists(atPath: script.path)
        else { throw ReviewHelperClientError.helperUnavailable }
        return ReviewHelperLaunchConfiguration(executableURL: node, arguments: [script.path])
    }
}

final class SystemReviewHelperProcess: ReviewHelperProcess, @unchecked Sendable {
    private let process = Process()
    private let standardInput = Pipe()
    private let standardOutput = Pipe()
    private let standardError = Pipe()
    private let lock = NSLock()
    private var storedTerminationStatus: Int32?
    private var stdoutContinuation: AsyncThrowingStream<Data, Error>.Continuation?
    private var stderrContinuation: AsyncStream<Data>.Continuation?

    private(set) lazy var stdoutBytes = AsyncThrowingStream<Data, Error> { continuation in
        self.stdoutContinuation = continuation
    }

    private(set) lazy var stderrBytes = AsyncStream<Data> { continuation in
        self.stderrContinuation = continuation
    }

    init(configuration: ReviewHelperLaunchConfiguration) {
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = standardError
    }

    convenience init() throws {
        try self.init(configuration: .resolve())
    }

    func start() throws {
        _ = stdoutBytes
        _ = stderrBytes
        standardOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stdoutContinuation?.yield(data)
        }
        standardError.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stderrContinuation?.yield(data)
        }
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.standardOutput.fileHandleForReading.readabilityHandler = nil
            self.standardError.fileHandleForReading.readabilityHandler = nil
            self.lock.withLock { self.storedTerminationStatus = process.terminationStatus }
            self.stdoutContinuation?.finish()
            self.stderrContinuation?.finish()
        }
        try process.run()
    }

    func write(_ data: Data) throws {
        try standardInput.fileHandleForWriting.write(contentsOf: data)
    }

    func terminate() {
        try? standardInput.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    func waitForExit() async -> Int32 {
        if let status = lock.withLock({ storedTerminationStatus }) { return status }
        return await Task.detached { [process] in
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}
