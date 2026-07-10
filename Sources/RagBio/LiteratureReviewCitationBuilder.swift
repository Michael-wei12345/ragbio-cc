import Foundation

enum LiteratureReviewCitationBuilder {
    static func make(
        summary: LiteratureReviewSummary,
        document: FullTextDocument,
        maxExcerptLength: Int = 420
    ) -> [LiteratureReviewSourceExcerpt] {
        let paragraphs = document.paragraphs.filter {
            clean($0.text).count >= 60
        }
        guard !paragraphs.isEmpty else { return [] }

        let targets = [
            Target(
                label: "Topic",
                summaryText: summary.topic,
                sectionTerms: ["abstract", "summary", "background", "introduction"]
            ),
            Target(
                label: "Methods",
                summaryText: summary.methods,
                sectionTerms: ["method", "materials", "participants", "procedure", "data"]
            ),
            Target(
                label: "Results",
                summaryText: summary.results,
                sectionTerms: ["result", "finding", "outcome"]
            ),
            Target(
                label: "Key Metrics",
                summaryText: summary.metrics.joined(separator: " "),
                sectionTerms: ["result", "method", "participants", "data", "table"],
                preferNumbers: true
            ),
            Target(
                label: "Outlook",
                summaryText: summary.outlook,
                sectionTerms: ["discussion", "conclusion", "limitation", "future"]
            )
        ].filter { !$0.summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        return targets.compactMap { target in
            bestParagraph(for: target, in: paragraphs).map {
                sourceExcerpt(
                    from: $0,
                    label: target.label,
                    maxLength: maxExcerptLength
                )
            }
        }
    }

    private struct Target {
        let label: String
        let summaryText: String
        let sectionTerms: [String]
        var preferNumbers = false
    }

    private static func bestParagraph(
        for target: Target,
        in paragraphs: [FullTextParagraph]
    ) -> FullTextParagraph? {
        let ranked = paragraphs.map { paragraph in
            (paragraph: paragraph, score: score(paragraph, for: target))
        }
        .filter { $0.score > 0 }
        .sorted {
            if $0.score == $1.score {
                return $0.paragraph.ordinal < $1.paragraph.ordinal
            }
            return $0.score > $1.score
        }
        return ranked.first?.paragraph
    }

    private static func score(_ paragraph: FullTextParagraph, for target: Target) -> Double {
        let text = clean(paragraph.text)
        guard text.count >= 60 else { return 0 }

        let lowerText = text.lowercased()
        let section = paragraph.section.lowercased()
        var value = 0.0

        if target.sectionTerms.contains(where: { section.contains($0) }) {
            value += 10
        }
        if target.sectionTerms.contains(where: { lowerText.contains($0) }) {
            value += 3
        }

        let summaryTokens = tokens(from: target.summaryText)
        if !summaryTokens.isEmpty {
            let paragraphTokens = tokens(from: text)
            let overlap = summaryTokens.intersection(paragraphTokens).count
            value += Double(overlap) / sqrt(Double(summaryTokens.count)) * 8
        }

        if target.preferNumbers {
            let summaryNumbers = metricTokens(from: target.summaryText)
            let paragraphNumbers = metricTokens(from: text)
            let numberOverlap = summaryNumbers.intersection(paragraphNumbers).count
            value += Double(numberOverlap) * 8
            if !paragraphNumbers.isEmpty {
                value += 4
            }
        }

        if target.label == "Topic", paragraph.ordinal <= 3 {
            value += 2
        }
        if text.count > 2_500 {
            value -= 2
        }
        return value
    }

    private static func sourceExcerpt(
        from paragraph: FullTextParagraph,
        label: String,
        maxLength: Int
    ) -> LiteratureReviewSourceExcerpt {
        LiteratureReviewSourceExcerpt(
            id: "\(label)-\(paragraph.id)",
            paragraphID: paragraph.id,
            label: label,
            locator: paragraph.locator,
            text: String(clean(paragraph.text).prefix(maxLength))
        )
    }

    private static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(from text: String) -> Set<String> {
        let stopwords: Set<String> = [
            "the", "and", "for", "with", "from", "into", "onto", "about", "between",
            "among", "using", "based", "study", "studies", "review", "analysis",
            "method", "methods", "result", "results", "conclusion", "conclusions",
            "in", "on", "of", "to", "a", "an", "is", "are", "was", "were", "this",
            "that", "these", "those", "their", "they", "we", "our"
        ]
        return Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 && !stopwords.contains($0) }
        )
    }

    private static func metricTokens(from text: String) -> Set<String> {
        let pattern = #"(?i)(p\s*[<=>]\s*0?\.\d+|r\s*=\s*-?0?\.\d+|\d+(?:\.\d+)?%?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: range)
        return Set(matches.compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange])
                .lowercased()
                .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        })
    }
}
