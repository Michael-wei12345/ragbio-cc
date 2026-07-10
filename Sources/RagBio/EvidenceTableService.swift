import Foundation

enum EvidenceTableService {
    struct Input {
        var query: String
        var rankedWorks: [Work]
        var scanDecisions: [String: ScanDecisionRecord]
        var accessStatusByWorkID: [String: EvidenceAccessStatus]
        var aiScores: [String: Int]
        var aiReasons: [String: String]
        var aiEvidenceLevels: [String: String]
        var summaries: [String: LiteratureReviewSummary]
        var sourceRefsByWorkID: [String: [EvidenceSourceRef]]
    }

    static func make(input: Input) -> EvidenceTable {
        let markedDecisions = input.scanDecisions.values.filter {
            $0.decision == .use || $0.decision == .maybe
        }
        let markedIDs = Set(markedDecisions.map(\.workID))
        let hasMarkedIncludedPapers = !markedIDs.isEmpty

        let sourceWorks: [Work]
        let warning: String?
        if hasMarkedIncludedPapers {
            sourceWorks = input.rankedWorks.filter { markedIDs.contains($0.id) }
            warning = nil
        } else {
            sourceWorks = input.rankedWorks
            warning = "No scan decisions yet. This table is based on current ranking."
        }

        let rows = sourceWorks
            .filter { input.scanDecisions[$0.id]?.decision != .exclude }
            .map { work in
                makeRow(work: work, input: input)
            }

        return EvidenceTable(
            id: UUID(),
            query: input.query,
            generatedAt: Date(),
            basedOnWorkIDs: rows.map(\.workID),
            rows: rows,
            warning: warning
        )
    }

    /// Builds rows for an explicit set of works, without the Use/Maybe re-selection that
    /// `make(input:)` applies. The caller decides exactly which works to include.
    static func rows(for works: [Work], input: Input) -> [EvidenceTableRow] {
        works
            .filter { input.scanDecisions[$0.id]?.decision != .exclude }
            .map { makeRow(work: $0, input: input) }
    }

    static func markdown(_ table: EvidenceTable) -> String {
        var lines: [String] = [
            "# Evidence Table",
            "",
            "Query: \(table.query)",
            "Generated: \(table.generatedAt.formatted(date: .abbreviated, time: .shortened))",
            ""
        ]
        if let warning = table.warning {
            lines.append("> \(warning)")
            lines.append("")
        }
        lines.append("| Decision | Paper | Year | Access | Key Metrics | Evidence |")
        lines.append("|---|---|---:|---|---|---|")
        for row in table.rows {
            lines.append(
                "| \(escapeMarkdownCell(row.scanDecision.shortTitle))"
                    + " | \(escapeMarkdownCell(row.title))"
                    + " | \(row.year.map(String.init) ?? "")"
                    + " | \(escapeMarkdownCell(row.accessStatus.title))"
                    + " | \(escapeMarkdownCell(row.summaryKeyMetrics ?? ""))"
                    + " | \(escapeMarkdownCell(rowEvidenceSummary(row))) |"
            )
        }
        return lines.joined(separator: "\n")
    }

    static func csv(_ table: EvidenceTable) -> String {
        let header = [
            "Decision", "Title", "Year", "Journal", "Access", "AI Score",
            "AI Reason", "Topic", "Methods", "Results", "Key Metrics", "Outlook",
            "Source Refs"
        ]
        let rows = table.rows.map { row in
            [
                row.scanDecision.shortTitle,
                row.title,
                row.year.map(String.init) ?? "",
                row.venue ?? "",
                row.accessStatus.title,
                row.aiScore.map { String(format: "%.0f", $0) } ?? "",
                row.aiReason ?? "",
                row.summaryTopic ?? "",
                row.summaryMethods ?? "",
                row.summaryResults ?? "",
                row.summaryKeyMetrics ?? "",
                row.summaryOutlook ?? "",
                row.sourceRefs.map {
                    "\($0.field): \($0.locator) - \($0.quotePreview)"
                }.joined(separator: "\n")
            ].map(escapeCSVCell).joined(separator: ",")
        }
        return ([header.map(escapeCSVCell).joined(separator: ",")] + rows)
            .joined(separator: "\n")
    }

    private static func makeRow(
        work: Work,
        input: Input
    ) -> EvidenceTableRow {
        let decisionRecord = input.scanDecisions[work.id]
        let summary = input.summaries[work.id]
        let abstract = work.abstractText
        return EvidenceTableRow(
            workID: work.id,
            title: work.title,
            year: work.publicationYear,
            authors: work.authorships.compactMap(\.author.displayName),
            venue: work.venue,
            doi: work.normalizedDOI,
            pmid: work.normalizedPMID,
            pmcid: work.normalizedPMCID,
            openAlexID: work.id,
            scanDecision: decisionRecord?.decision ?? .unreviewed,
            accessStatus: input.accessStatusByWorkID[work.id] ?? accessStatusFallback(for: work),
            aiScore: input.aiScores[work.id].map(Double.init),
            aiReason: input.aiReasons[work.id],
            evidenceLevelLabel: input.aiEvidenceLevels[work.id],
            abstractText: abstract,
            abstractEvidence: abstract.map { String($0.prefix(600)) },
            summaryTopic: summary?.topic,
            summaryMethods: summary?.methods,
            summaryResults: summary?.results,
            summaryKeyMetrics: summary?.metrics.joined(separator: "; "),
            summaryOutlook: summary?.outlook,
            sourceRefs: input.sourceRefsByWorkID[work.id] ?? [],
            userNote: decisionRecord?.note
        )
    }

    private static func accessStatusFallback(for work: Work) -> EvidenceAccessStatus {
        if work.abstractText != nil { return .abstractOnly }
        return .metadataOnly
    }

    private static func rowEvidenceSummary(_ row: EvidenceTableRow) -> String {
        if let results = row.summaryResults, !results.isEmpty {
            return results
        }
        if let abstractEvidence = row.abstractEvidence, !abstractEvidence.isEmpty {
            return abstractEvidence
        }
        return row.aiReason ?? ""
    }

    private static func escapeMarkdownCell(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    private static func escapeCSVCell(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if escaped.contains(",") || escaped.contains("\"") || escaped.contains("\n") {
            return "\"\(escaped)\""
        }
        return escaped
    }
}
