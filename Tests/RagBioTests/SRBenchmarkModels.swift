import Foundation
@testable import RagBio

enum SRBenchmarkReportRole: String, Codable {
    case primary
    case followUp = "follow_up"
    case subgroup
    case safety
    case protocolRecord = "protocol"
    case registry
}

struct SRBenchmarkIdentity: Codable, Hashable {
    var pmid: String?
    var doi: String?
    var registryIDs: [String] = []
    var title: String?

    init(
        pmid: String? = nil,
        doi: String? = nil,
        registryIDs: [String] = [],
        title: String? = nil
    ) {
        self.pmid = pmid
        self.doi = doi
        self.registryIDs = registryIDs
        self.title = title
    }

    init(work: Work) {
        pmid = work.normalizedPMID
        doi = work.normalizedDOI
        title = work.title
        registryIDs = Self.registryIdentifiers(
            in: [work.id, work.title, work.abstractText ?? ""].joined(separator: " ")
        )
    }

    func matches(_ other: Self) -> Bool {
        let left = normalizedStrongIdentifiers
        let right = other.normalizedStrongIdentifiers
        if !left.isEmpty, !right.isEmpty, !left.isDisjoint(with: right) {
            return true
        }
        guard let leftTitle = Self.normalizedTitle(title),
              let rightTitle = Self.normalizedTitle(other.title),
              leftTitle.count >= 20,
              rightTitle.count >= 20 else {
            return false
        }
        return leftTitle == rightTitle
    }

    var hasStableIdentifier: Bool {
        !normalizedStrongIdentifiers.isEmpty
    }

    private var normalizedStrongIdentifiers: Set<String> {
        var values = Set<String>()
        if let pmid = Self.normalizedPMID(pmid) {
            values.insert("pmid:\(pmid)")
        }
        if let doi = Self.normalizedDOI(doi) {
            values.insert("doi:\(doi)")
        }
        for registryID in registryIDs {
            let normalized = registryID.uppercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                values.insert("registry:\(normalized)")
            }
        }
        return values
    }

    private static func normalizedPMID(_ value: String?) -> String? {
        guard let value else { return nil }
        let digits = value.filter(\.isNumber)
        return digits.isEmpty ? nil : digits
    }

    private static func normalizedDOI(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased()
            .replacingOccurrences(
                of: #"^(https?://(dx\.)?doi\.org/|doi:\s*)"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: " /"))
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func registryIdentifiers(in value: String) -> [String] {
        let pattern = #"\b(?:NCT\d{8}|ISRCTN\d{6,10}|EUCTR\d{4}-\d{6}-\d{2})\b"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            Range(match.range, in: value).map { String(value[$0]).uppercased() }
        }
    }
}

struct SRBenchmarkGoldReport: Codable {
    let role: SRBenchmarkReportRole
    let identity: SRBenchmarkIdentity
}

struct SRBenchmarkStudyFamily: Codable {
    let id: String
    let name: String
    let critical: Bool
    let reports: [SRBenchmarkGoldReport]
}

struct SRBenchmarkReviewMetadata: Codable {
    let citation: String
    let sourceURL: String
    let searchCutoff: String
    let identity: SRBenchmarkIdentity
}

struct SRBenchmarkQuestion: Codable {
    let naturalLanguageInput: String
    let structuredInput: String
    let eligibilityCriteria: [String]
    let profile: ResearchQuestionProfile
}

struct SRBenchmarkManifest: Codable {
    let schemaVersion: Int
    let id: String
    let review: SRBenchmarkReviewMetadata
    let question: SRBenchmarkQuestion
    let goldStudyFamilies: [SRBenchmarkStudyFamily]
    let contextualSources: [SRBenchmarkIdentity]
    let prohibitedCitationSeeds: [SRBenchmarkIdentity]
    let openAlexQueries: [String]
    let pubMedQueries: [String]
    let clinicalTrialsQueries: [String]
}

struct SRBenchmarkRecord {
    let identity: SRBenchmarkIdentity
    let publicationDate: String?
    let score: Int?
    let usedAsCitationSeed: Bool

    init(
        identity: SRBenchmarkIdentity,
        publicationDate: String? = nil,
        score: Int? = nil,
        usedAsCitationSeed: Bool = false
    ) {
        self.identity = identity
        self.publicationDate = publicationDate
        self.score = score
        self.usedAsCitationSeed = usedAsCitationSeed
    }

    init(work: Work, score: Int? = nil, usedAsCitationSeed: Bool = false) {
        identity = SRBenchmarkIdentity(work: work)
        publicationDate = work.publicationDate
        self.score = score
        self.usedAsCitationSeed = usedAsCitationSeed
    }
}

struct SRBenchmarkMetrics {
    let reviewID: String
    let goldFamilyCount: Int
    let foundFamilyIDs: Set<String>
    let criticalMissFamilyIDs: Set<String>
    let familyRecall: Double
    let recallAt20: Double
    let recallAt50: Double
    let precisionAt20: Double
    let recordsToReach95PercentRecall: Int?
    let thresholdedFamilyRecall: Double?
    let criticalFamiliesBelowThreshold: Set<String>
    let prohibitedCitationSeedMatches: [SRBenchmarkIdentity]
}

struct SRBenchmarkRankedDiagnostic: Codable {
    let rank: Int
    let score: Int
    let work: Work
    let card: StructuredEvidenceCard
}

enum SRBenchmarkEvaluator {
    static func evaluate(
        manifest: SRBenchmarkManifest,
        rankedRecords: [SRBenchmarkRecord],
        visibleScoreThreshold: Int = 5
    ) -> SRBenchmarkMetrics {
        let records = rankedRecords.filter { record in
            if matchedFamilyID(
                record: record,
                families: manifest.goldStudyFamilies
            ) != nil {
                // Some journals assign a later issue date to a report that was already
                // available online before the review's search cutoff.
                return true
            }
            guard let publicationDate = record.publicationDate else { return true }
            return publicationDate <= manifest.review.searchCutoff
        }
        let allFamilyIDs = Set(manifest.goldStudyFamilies.map(\.id))
        let criticalFamilyIDs = Set(
            manifest.goldStudyFamilies.filter(\.critical).map(\.id)
        )
        let foundFamilyIDs = matchedFamilyIDs(
            records: records,
            families: manifest.goldStudyFamilies
        )
        let top20 = Array(records.prefix(20))
        let top50 = Array(records.prefix(50))
        let top20FamilyIDs = matchedFamilyIDs(
            records: top20,
            families: manifest.goldStudyFamilies
        )
        let top50FamilyIDs = matchedFamilyIDs(
            records: top50,
            families: manifest.goldStudyFamilies
        )
        let usefulTop20 = top20.filter { record in
            matchedFamilyID(record: record, families: manifest.goldStudyFamilies) != nil
                || manifest.contextualSources.contains(where: {
                    $0.matches(record.identity)
                })
        }.count
        let hasScores = records.contains { $0.score != nil }
        let thresholdedRecords = records.filter {
            guard let score = $0.score else { return false }
            return score >= visibleScoreThreshold
        }
        let thresholdedFamilyIDs = matchedFamilyIDs(
            records: thresholdedRecords,
            families: manifest.goldStudyFamilies
        )
        let prohibitedSeedMatches: [SRBenchmarkIdentity] = rankedRecords.compactMap { record in
            guard record.usedAsCitationSeed,
                  manifest.prohibitedCitationSeeds.contains(where: {
                      $0.matches(record.identity)
                  }) else {
                return nil
            }
            return record.identity
        }

        return SRBenchmarkMetrics(
            reviewID: manifest.id,
            goldFamilyCount: allFamilyIDs.count,
            foundFamilyIDs: foundFamilyIDs,
            criticalMissFamilyIDs: criticalFamilyIDs.subtracting(foundFamilyIDs),
            familyRecall: recall(found: foundFamilyIDs.count, total: allFamilyIDs.count),
            recallAt20: recall(found: top20FamilyIDs.count, total: allFamilyIDs.count),
            recallAt50: recall(found: top50FamilyIDs.count, total: allFamilyIDs.count),
            precisionAt20: top20.isEmpty ? 0 : Double(usefulTop20) / Double(top20.count),
            recordsToReach95PercentRecall: recordsToReachRecall(
                0.95,
                records: records,
                families: manifest.goldStudyFamilies
            ),
            thresholdedFamilyRecall: hasScores
                ? recall(found: thresholdedFamilyIDs.count, total: allFamilyIDs.count)
                : nil,
            criticalFamiliesBelowThreshold: hasScores
                ? criticalFamilyIDs
                    .intersection(foundFamilyIDs)
                    .subtracting(thresholdedFamilyIDs)
                : [],
            prohibitedCitationSeedMatches: prohibitedSeedMatches
        )
    }

    static func matchedFamilyIDs(
        records: [SRBenchmarkRecord],
        families: [SRBenchmarkStudyFamily]
    ) -> Set<String> {
        Set(records.compactMap { matchedFamilyID(record: $0, families: families) })
    }

    private static func matchedFamilyID(
        record: SRBenchmarkRecord,
        families: [SRBenchmarkStudyFamily]
    ) -> String? {
        families.first { family in
            family.reports.contains { $0.identity.matches(record.identity) }
        }?.id
    }

    private static func recall(found: Int, total: Int) -> Double {
        total == 0 ? 0 : Double(found) / Double(total)
    }

    private static func recordsToReachRecall(
        _ target: Double,
        records: [SRBenchmarkRecord],
        families: [SRBenchmarkStudyFamily]
    ) -> Int? {
        guard !families.isEmpty else { return 0 }
        let required = Int(ceil(Double(families.count) * target))
        var found = Set<String>()
        for (index, record) in records.enumerated() {
            if let familyID = matchedFamilyID(record: record, families: families) {
                found.insert(familyID)
            }
            if found.count >= required {
                return index + 1
            }
        }
        return nil
    }
}

enum SRBenchmarkFixtureLoader {
    static var manifestDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Benchmarks/SystematicReview/Manifests")
    }

    static func loadAll() throws -> [SRBenchmarkManifest] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: manifestDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { url in
            try JSONDecoder().decode(
                SRBenchmarkManifest.self,
                from: Data(contentsOf: url)
            )
        }
    }
}

enum SRBenchmarkCandidateCache {
    private static var directory: URL {
        SRBenchmarkFixtureLoader.manifestDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Cache")
    }

    static func save(_ works: [Work], reviewID: String) throws {
        try save(works, reviewID: reviewID, stage: "pre480")
    }

    static func save(_ works: [Work], reviewID: String, stage: String) throws {
        try saveJSON(works, reviewID: reviewID, stage: stage)
    }

    static func saveJSON<T: Encodable>(
        _ value: T,
        reviewID: String,
        stage: String
    ) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(
            to: directory.appendingPathComponent("\(reviewID)-\(stage).json"),
            options: .atomic
        )
    }

    static func load(reviewID: String) throws -> [Work] {
        try load(reviewID: reviewID, stage: "pre480")
    }

    static func load(reviewID: String, stage: String) throws -> [Work] {
        try loadJSON(
            [Work].self,
            reviewID: reviewID,
            stage: stage
        )
    }

    static func loadJSON<T: Decodable>(
        _ type: T.Type,
        reviewID: String,
        stage: String
    ) throws -> T {
        let url = directory.appendingPathComponent("\(reviewID)-\(stage).json")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}
