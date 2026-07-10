import Foundation

struct LiteratureReviewSummary: Codable, Hashable {
    let topic: String
    let methods: String
    let results: String
    let outlook: String
    let metrics: [String]
}

enum LiteratureReviewSummaryBuilder {
    static func make(work: Work, document: FullTextDocument) -> LiteratureReviewSummary {
        let paragraphs = document.paragraphs.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let allText = paragraphs.map(\.text).joined(separator: " ")
        let allSentences = paragraphs.flatMap { EvidenceExtractor.sentences(from: $0.text) }

        let topic = sectionText(
            in: paragraphs,
            matching: ["abstract", "summary", "background", "introduction"],
            fallbackToFirst: true
        )
            ?? firstSentence(in: allSentences, matching: ["aim", "objective", "investigate", "examine"])
            ?? work.title
        let methods = sectionText(
            in: paragraphs,
            matching: ["method", "methods", "materials", "participants", "procedure"]
        )
            ?? firstSentence(in: allSentences, matching: methodTerms)
            ?? "The full text excerpts do not clearly report the study design, data source, or sample."
        let results = sectionText(
            in: paragraphs,
            matching: ["result", "results", "finding", "findings"]
        )
            ?? firstSentence(in: allSentences, matching: resultTerms)
            ?? "The full text excerpts do not clearly report the main findings."
        let outlook = sectionText(
            in: paragraphs,
            matching: ["discussion", "conclusion", "conclusions", "limitation", "future"]
        )
            ?? firstSentence(in: allSentences, matching: outlookTerms)
            ?? "The full text excerpts do not clearly report limitations, implications, or future work."

        return LiteratureReviewSummary(
            topic: summarize(topic),
            methods: summarize(methods),
            results: summarize(results),
            outlook: summarize(outlook),
            metrics: keyMetrics(from: EvidenceExtractor.sentences(from: allText))
        )
    }

    static func make(work: Work, abstract: String) -> LiteratureReviewSummary {
        let cleanAbstract = clean(abstract)
        let sentences = EvidenceExtractor.sentences(from: cleanAbstract)
        let sections = sections(from: sentences)

        let topic = sections["aims"]
            ?? sections["background"]
            ?? sentences.first
            ?? work.title
        let methods = sections["methods"]
            ?? firstSentence(in: sentences, matching: methodTerms)
            ?? "The abstract does not clearly report the study design, data source, or sample."
        let results = sections["results"]
            ?? firstSentence(in: sentences, matching: resultTerms)
            ?? "The abstract does not clearly report the main findings."
        let outlook = sections["conclusions"]
            ?? sections["outlook"]
            ?? firstSentence(in: sentences, matching: outlookTerms)
            ?? sentences.last
            ?? "The abstract does not clearly report limitations, implications, or future work."

        return LiteratureReviewSummary(
            topic: shorten(topic),
            methods: shorten(methods),
            results: shorten(results),
            outlook: shorten(outlook),
            metrics: keyMetrics(from: sentences)
        )
    }

    private static let methodTerms = [
        "method", "review", "searched", "database", "pubmed", "sample",
        "participants", "cohort", "trial", "questionnaire", "meta-analysis"
    ]
    private static let resultTerms = [
        "result", "finding", "found", "showed", "indicates", "suggest",
        "associated", "correlated", "improved", "higher", "lower"
    ]
    private static let outlookTerms = [
        "conclusion", "future", "further research", "should", "requires",
        "needed", "limitations", "implications"
    ]

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sections(from sentences: [String]) -> [String: String] {
        var values: [String: [String]] = [:]
        var currentKey: String?

        for sentence in sentences {
            if let start = sectionStart(sentence) {
                currentKey = start.key
                values[start.key, default: []].append(start.text)
            } else if let currentKey {
                values[currentKey, default: []].append(sentence)
            }
        }

        return values.mapValues { shorten($0.joined(separator: " ")) }
    }

    private static func sectionStart(_ sentence: String) -> (key: String, text: String)? {
        let headings: [(heading: String, key: String)] = [
            ("background", "background"),
            ("aims", "aims"),
            ("aim", "aims"),
            ("objectives", "aims"),
            ("objective", "aims"),
            ("methods", "methods"),
            ("method", "methods"),
            ("methodology", "methods"),
            ("results", "results"),
            ("findings", "results"),
            ("conclusions", "conclusions"),
            ("conclusion", "conclusions"),
            ("limitations", "outlook"),
            ("future directions", "outlook"),
            ("implications", "outlook")
        ]
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for item in headings {
            let plainPrefix = item.heading + " "
            let colonPrefix = item.heading + ":"
            let fullWidthColonPrefix = item.heading + "："
            let prefix: String?
            if lower.hasPrefix(plainPrefix) {
                prefix = plainPrefix
            } else if lower.hasPrefix(colonPrefix) {
                prefix = colonPrefix
            } else if lower.hasPrefix(fullWidthColonPrefix) {
                prefix = fullWidthColonPrefix
            } else {
                prefix = nil
            }
            if let prefix {
                let index = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
                let body = trimmed[index...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return (item.key, body.isEmpty ? trimmed : body)
            }
        }
        return nil
    }

    private static func firstSentence(in sentences: [String], matching terms: [String]) -> String? {
        sentences.first { sentence in
            let lower = sentence.lowercased()
            return terms.contains { lower.contains($0) }
        }
    }

    private static func sectionText(
        in paragraphs: [FullTextParagraph],
        matching terms: [String],
        fallbackToFirst: Bool = false
    ) -> String? {
        let matched = paragraphs.filter { paragraph in
            let section = paragraph.section.lowercased()
            return terms.contains { section.contains($0) }
        }
        let source = matched.isEmpty && fallbackToFirst ? Array(paragraphs.prefix(3)) : matched
        let selected = source
            .prefix(5)
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? nil : selected
    }

    private static func keyMetrics(from sentences: [String]) -> [String] {
        let patterns = [
            #"(?i)\bn\s*=\s*\d+"#,
            #"(?i)\b\d+\s*(participants|patients|children|adults|studies|sources|papers|records)\b"#,
            #"(?i)\b\d+(\.\d+)?\s*%"#,
            #"(?i)\bp\s*[<=>]\s*0?\.\d+"#,
            #"(?i)\br\s*=\s*-?0?\.\d+"#,
            #"(?i)\b\d{1,2}\s+[A-Z][a-z]+\s+\d{4}\b"#
        ]
        return sentences
            .filter { sentence in
                patterns.contains { pattern in
                    sentence.range(of: pattern, options: .regularExpression) != nil
                }
            }
            .map { shorten($0) }
            .uniqued()
            .prefix(5)
            .map { $0 }
    }

    private static func shorten(_ text: String, limit: Int = 260) -> String {
        let value = clean(text)
        guard value.count > limit else { return value }
        return String(value.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    private static func summarize(_ text: String) -> String {
        let sentences = EvidenceExtractor.sentences(from: clean(text))
        let selected = sentences.prefix(2).joined(separator: " ")
        return shorten(selected.isEmpty ? text : selected, limit: 360)
    }
}
