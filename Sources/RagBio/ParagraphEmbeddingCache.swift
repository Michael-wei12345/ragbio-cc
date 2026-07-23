import CryptoKit
import Foundation

actor ParagraphEmbeddingCache {
    static let shared = ParagraphEmbeddingCache()

    private struct CacheFile: Codable {
        let schemaVersion: Int
        let contentFingerprint: String
        let modelSignature: String
        let dimension: Int
        var vectors: [String: Data]
    }

    private let directory: URL
    private let storagePolicy: FullTextCache

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            self.directory = applicationSupport
                .appendingPathComponent("RagBio", isDirectory: true)
                .appendingPathComponent("FullText", isDirectory: true)
        }
        storagePolicy = FullTextCache(directory: self.directory)
        try? FileManager.default.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true
        )
    }

    func vectors(
        workID: String,
        contentFingerprint: String,
        modelSignature: String,
        dimension: Int,
        paragraphIDs: Set<String>
    ) -> [String: [Double]] {
        let url = fileURL(workID: workID)
        guard let data = try? Data(contentsOf: url),
              let cached = try? PropertyListDecoder().decode(CacheFile.self, from: data),
              cached.schemaVersion == 1,
              cached.contentFingerprint == contentFingerprint,
              cached.modelSignature == modelSignature,
              cached.dimension == dimension else {
            return [:]
        }
        touch(url)
        return cached.vectors.reduce(into: [:]) { result, item in
            guard paragraphIDs.contains(item.key),
                  let vector = decodeVector(item.value, dimension: dimension) else { return }
            result[item.key] = vector
        }
    }

    func merge(
        _ vectors: [String: [Double]],
        workID: String,
        contentFingerprint: String,
        modelSignature: String,
        dimension: Int
    ) async {
        guard !vectors.isEmpty else { return }
        let url = fileURL(workID: workID)
        var stored: [String: Data] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? PropertyListDecoder().decode(CacheFile.self, from: data),
           existing.schemaVersion == 1,
           existing.contentFingerprint == contentFingerprint,
           existing.modelSignature == modelSignature,
           existing.dimension == dimension {
            stored = existing.vectors
        }
        for (paragraphID, vector) in vectors where vector.count == dimension {
            stored[paragraphID] = encodeVector(vector)
        }
        let value = CacheFile(
            schemaVersion: 1,
            contentFingerprint: contentFingerprint,
            modelSignature: modelSignature,
            dimension: dimension,
            vectors: stored
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
        touch(url)
        await storagePolicy.enforceStoragePolicy()
    }

    nonisolated static func contentFingerprint(
        paragraphs: [FullTextParagraph]
    ) -> String {
        var hasher = SHA256()
        hasher.update(data: Data("ragbio-paragraphs-v1".utf8))
        for paragraph in paragraphs {
            hasher.update(data: Data(paragraph.id.utf8))
            hasher.update(data: Data(paragraph.section.utf8))
            hasher.update(data: Data(paragraph.text.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(workID: String) -> URL {
        let digest = SHA256.hash(data: Data(workID.lowercased().utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory
            .appendingPathComponent("embedding_\(digest)")
            .appendingPathExtension("plist")
    }

    private func encodeVector(_ vector: [Double]) -> Data {
        var floats = vector.map(Float.init)
        return floats.withUnsafeMutableBytes { Data($0) }
    }

    private func decodeVector(_ data: Data, dimension: Int) -> [Double]? {
        guard data.count == dimension * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            (0..<dimension).map { index in
                Double(
                    rawBuffer.loadUnaligned(
                        fromByteOffset: index * MemoryLayout<Float>.size,
                        as: Float.self
                    )
                )
            }
        }
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()],
            ofItemAtPath: url.path
        )
    }
}
