import Foundation
import Testing
@testable import RagBio

@Suite struct ReviewJobStoreTests {
    @Test func createsAndReloadsVersionedJobsWithImmutableManifest() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewJobStore(root: root)
        let record = record(query: "gut microbiota")
        let firstID = UUID()
        let firstManifest = ReviewInputManifest.make(
            record: record,
            jobID: firstID,
            createdAt: Date(timeIntervalSince1970: 20)
        )

        let first = try await store.create(manifest: firstManifest)
        let secondID = UUID()
        let secondManifest = ReviewInputManifest.make(
            record: record,
            jobID: secondID,
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let second = try await store.create(manifest: secondManifest)

        #expect(first.version == 1)
        #expect(second.version == 2)
        #expect(try await store.manifest(jobID: firstID) == firstManifest)
        #expect(try await store.latest(searchHistoryID: record.id)?.id == secondID)
    }

    @Test func allowsOnlyOneRunningJob() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewJobStore(root: root)
        let first = try await store.create(manifest: manifest(query: "first"))
        let second = try await store.create(manifest: manifest(query: "second"))
        _ = try await store.update(id: first.id, status: .running)

        await #expect(throws: ReviewJobStoreError.anotherJobIsRunning) {
            _ = try await store.update(id: second.id, status: .running)
        }
    }

    @Test func bootstrapPausesRunningJobInsteadOfRestartingIt() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewJobStore(root: root)
        let created = try await store.create(manifest: manifest(query: "resume me"))
        _ = try await store.update(
            id: created.id,
            status: .running,
            stage: .extracting,
            completedPaperCount: 1
        )

        let restored = try await store.bootstrap()

        #expect(restored.first?.status == .paused)
        #expect(restored.first?.stage == .extracting)
        #expect(restored.first?.completedPaperCount == 1)
    }

    @Test func doesNotDeleteCompletedVersion() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewJobStore(root: root)
        let created = try await store.create(manifest: manifest(query: "complete"))
        _ = try await store.update(id: created.id, status: .completed)

        try await store.deleteIncomplete(id: created.id)

        #expect(try await store.job(id: created.id).status == .completed)
    }

    @Test func persistsFailureCategoryAndClearsItWhenRetrying() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReviewJobStore(root: root)
        let created = try await store.create(manifest: manifest(query: "recover"))

        _ = try await store.update(
            id: created.id,
            status: .failed,
            blockMessage: "The generated review data did not pass validation.",
            failureCategory: .outputValidation
        )
        #expect(try await store.job(id: created.id).failureCategory == .outputValidation)

        _ = try await store.update(id: created.id, status: .running)
        #expect(try await store.job(id: created.id).failureCategory == nil)
    }

    private func manifest(query: String) -> ReviewInputManifest {
        ReviewInputManifest.make(
            record: record(query: query),
            jobID: UUID()
        )
    }

    private func record(query: String) -> SearchHistoryRecord {
        let work = makeWork(id: "https://openalex.org/W\(UUID().uuidString)")
        var ledger = UseLedger()
        ledger.mark(work, at: Date(timeIntervalSince1970: 5))
        return makeRecord(
            query: query,
            works: [work],
            date: Date(timeIntervalSince1970: 10),
            useLedger: ledger
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ReviewJobStoreTests-\(UUID().uuidString)", isDirectory: true)
    }
}
