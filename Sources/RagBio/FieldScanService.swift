import Foundation

struct FieldScanService {
    var planner = AIQueryPlanner()

    func generate(
        table: EvidenceTable,
        normalizedQuery: String?,
        configuration: AIProviderConfiguration
    ) async throws -> FieldScanReport {
        try await generate(
            rows: selectedRows(from: table),
            query: table.query,
            normalizedQuery: normalizedQuery,
            configuration: configuration
        )
    }

    /// Generates a field synthesis from an explicit, pre-selected row set. The caller decides
    /// which papers to include. Reused by the field-level summary feature.
    func generate(
        rows: [EvidenceTableRow],
        query: String,
        normalizedQuery: String?,
        configuration: AIProviderConfiguration
    ) async throws -> FieldScanReport {
        guard !rows.isEmpty else {
            throw FieldScanError.noRows
        }
        let snapshot = inputSnapshot(rows: rows)
        let draft = try await planner.fieldScanDraft(
            query: query,
            normalizedQuery: normalizedQuery,
            rows: rows,
            snapshot: snapshot,
            configuration: configuration
        )
        return validate(
            draft: draft,
            query: query,
            normalizedQuery: normalizedQuery,
            rows: rows,
            snapshot: snapshot
        )
    }

    private func selectedRows(from table: EvidenceTable) -> [EvidenceTableRow] {
        let marked = table.rows.filter {
            $0.scanDecision == .use || $0.scanDecision == .maybe
        }
        let source = marked.isEmpty ? table.rows : marked
        return source.filter { $0.scanDecision != .exclude }
    }

    private func inputSnapshot(rows: [EvidenceTableRow]) -> FieldScanInputSnapshot {
        let fullTextCount = rows.filter(\.accessStatus.isFullTextSupported).count
        let abstractOnlyCount = rows.filter { $0.accessStatus == .abstractOnly }.count
        let unreviewedCount = rows.filter { $0.scanDecision == .unreviewed }.count
        let generatedFromDecisions = rows.contains {
            $0.scanDecision == .use || $0.scanDecision == .maybe
        }
        return FieldScanInputSnapshot(
            rowCount: rows.count,
            fullTextSupportedCount: fullTextCount,
            abstractOnlyCount: abstractOnlyCount,
            unreviewedCount: unreviewedCount,
            generatedFromDecisions: generatedFromDecisions
        )
    }

    private func validate(
        draft: FieldScanDraftResponse,
        query: String,
        normalizedQuery: String?,
        rows: [EvidenceTableRow],
        snapshot: FieldScanInputSnapshot
    ) -> FieldScanReport {
        let rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.workID, $0) })
        let validIDs = Set(rowByID.keys)

        func cleanIDs(_ ids: [String]) -> [String] {
            ids.filter { validIDs.contains($0) }.uniqued()
        }

        func supportLevel(_ ids: [String]) -> EvidenceSupportLevel {
            let statuses = ids.compactMap { rowByID[$0]?.accessStatus }
            guard !statuses.isEmpty else { return .metadataOnly }
            if statuses.allSatisfy(\.isFullTextSupported) { return .fullTextOnly }
            if statuses.contains(where: \.isFullTextSupported) {
                return .mixedFullTextAndAbstract
            }
            if statuses.allSatisfy({ $0 == .abstractOnly }) { return .abstractOnly }
            return .metadataOnly
        }

        let themes = draft.mainThemes.compactMap { item -> ResearchTheme? in
            let ids = cleanIDs(item.supportingWorkIDs)
            guard !ids.isEmpty else { return nil }
            return ResearchTheme(
                id: UUID(),
                name: item.name,
                summary: item.summary,
                supportingWorkIDs: ids,
                evidenceLevel: supportLevel(ids)
            )
        }
        .prefixArray(7)

        func claims(_ items: [FieldScanDraftClaim], limit: Int) -> [SupportedClaim] {
            items.compactMap { item -> SupportedClaim? in
                let ids = cleanIDs(item.supportingWorkIDs)
                guard !ids.isEmpty else { return nil }
                return SupportedClaim(
                    id: UUID(),
                    text: item.text,
                    supportingWorkIDs: ids,
                    evidenceLevel: supportLevel(ids),
                    caution: item.caution
                )
            }
            .prefixArray(limit)
        }

        let mustRead = draft.mustReadPapers.compactMap { item -> MustReadPaper? in
            guard validIDs.contains(item.workID) else { return nil }
            let title = rowByID[item.workID]?.title ?? item.title
            return MustReadPaper(
                workID: item.workID,
                title: title,
                reason: item.reason,
                category: item.category
            )
        }
        .prefixArray(15)

        var limitations = draft.limitations
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if snapshot.rowCount < 5 {
            limitations.append("This Field Scan may be weak because it is based on fewer than 5 papers.")
        }
        if snapshot.fullTextSupportedCount == 0 {
            limitations.append("All included evidence is abstract-only or metadata-only; conclusions should be treated as preliminary.")
        }

        let overview = draft.fieldOverview
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return FieldScanReport(
            id: UUID(),
            query: query,
            normalizedQuery: normalizedQuery,
            generatedAt: Date(),
            basedOnWorkIDs: rows.map(\.workID),
            inputSnapshot: snapshot,
            fieldOverview: overview.isEmpty
                ? "No field overview was returned from the model. Review the Evidence Table rows directly."
                : overview,
            mainThemes: themes.prefixArray(7),
            keyFindings: claims(draft.keyFindings, limit: 8),
            conflictingEvidence: claims(draft.conflictingEvidence, limit: 5),
            commonMethods: claims(draft.commonMethods, limit: 8),
            researchGaps: claims(draft.researchGaps, limit: 8),
            futureDirections: claims(draft.futureDirections, limit: 8),
            mustReadPapers: mustRead,
            limitations: Array(limitations.prefix(10))
        )
    }
}

enum FieldScanError: LocalizedError {
    case noRows

    var errorDescription: String? {
        switch self {
        case .noRows:
            return "Evidence Table has no rows to scan."
        }
    }
}

struct FieldScanDraftResponse: Decodable {
    let fieldOverview: String
    let mainThemes: [FieldScanDraftTheme]
    let keyFindings: [FieldScanDraftClaim]
    let conflictingEvidence: [FieldScanDraftClaim]
    let commonMethods: [FieldScanDraftClaim]
    let researchGaps: [FieldScanDraftClaim]
    let futureDirections: [FieldScanDraftClaim]
    let mustReadPapers: [FieldScanDraftMustRead]
    let limitations: [String]

    enum CodingKeys: String, CodingKey {
        case fieldOverview = "field_overview"
        case mainThemes = "main_themes"
        case keyFindings = "key_findings"
        case conflictingEvidence = "conflicting_evidence"
        case commonMethods = "common_methods"
        case researchGaps = "research_gaps"
        case futureDirections = "future_directions"
        case mustReadPapers = "must_read_papers"
        case limitations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fieldOverview = try container.decodeIfPresent(String.self, forKey: .fieldOverview) ?? ""
        mainThemes = try container.decodeIfPresent([FieldScanDraftTheme].self, forKey: .mainThemes) ?? []
        keyFindings = try container.decodeIfPresent([FieldScanDraftClaim].self, forKey: .keyFindings) ?? []
        conflictingEvidence = try container.decodeIfPresent([FieldScanDraftClaim].self, forKey: .conflictingEvidence) ?? []
        commonMethods = try container.decodeIfPresent([FieldScanDraftClaim].self, forKey: .commonMethods) ?? []
        researchGaps = try container.decodeIfPresent([FieldScanDraftClaim].self, forKey: .researchGaps) ?? []
        futureDirections = try container.decodeIfPresent([FieldScanDraftClaim].self, forKey: .futureDirections) ?? []
        mustReadPapers = try container.decodeIfPresent([FieldScanDraftMustRead].self, forKey: .mustReadPapers) ?? []
        limitations = try container.decodeIfPresent([String].self, forKey: .limitations) ?? []
    }
}

struct FieldScanDraftTheme: Decodable {
    let name: String
    let summary: String
    let supportingWorkIDs: [String]

    enum CodingKeys: String, CodingKey {
        case name, summary
        case supportingWorkIDs = "supporting_work_ids"
    }
}

struct FieldScanDraftClaim: Decodable {
    let text: String
    let supportingWorkIDs: [String]
    let caution: String?

    enum CodingKeys: String, CodingKey {
        case text, caution
        case supportingWorkIDs = "supporting_work_ids"
    }
}

struct FieldScanDraftMustRead: Decodable {
    let workID: String
    let title: String
    let reason: String
    let category: MustReadCategory

    enum CodingKeys: String, CodingKey {
        case title, reason, category
        case workID = "work_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workID = try container.decode(String.self, forKey: .workID)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? workID
        reason = try container.decodeIfPresent(String.self, forKey: .reason) ?? "Included in the Evidence Table."
        let rawCategory = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        category = Self.decodeCategory(rawCategory)
    }

    private static func decodeCategory(_ rawValue: String) -> MustReadCategory {
        if let exact = MustReadCategory(rawValue: rawValue) {
            return exact
        }
        switch rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_") {
        case "foundational":
            return .foundational
        case "recent":
            return .recent
        case "methodologically_useful", "methodological", "methods":
            return .methodologicallyUseful
        case "full_text_available", "fulltextavailable", "full_text":
            return .fullTextAvailable
        case "highly_relevant", "highlyrelevant", "relevant":
            return .highlyRelevant
        default:
            return .highlyRelevant
        }
    }
}

private extension Array {
    func prefixArray(_ maxLength: Int) -> [Element] {
        Array(prefix(maxLength))
    }
}
