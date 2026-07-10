import Foundation
import NaturalLanguage

enum HybridRetriever {
    static func search(
        query: String,
        paragraphs: [FullTextParagraph],
        limit: Int = 20
    ) -> [PassageHit] {
        let terms = tokenize(query).uniqued()
        guard !terms.isEmpty, !paragraphs.isEmpty else { return [] }

        let documentFrequency = Dictionary(uniqueKeysWithValues: terms.map { term in
            let count = paragraphs.reduce(0) {
                $0 + (tokenize($1.text).contains(term) ? 1 : 0)
            }
            return (term, count)
        })

        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        let queryVector = embedding?.vector(for: query)
        var raw: [(FullTextParagraph, Double, Double, [String])] = []

        for paragraph in paragraphs {
            let tokens = tokenize(paragraph.text)
            let tokenCounts = Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +)
            var lexical = 0.0
            var matches: [String] = []

            for term in terms {
                guard let frequency = tokenCounts[term], frequency > 0 else { continue }
                matches.append(term)
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log((Double(paragraphs.count) + 1) / (df + 1)) + 1
                lexical += (1 + log(Double(frequency))) * idf
            }

            let lowerText = paragraph.text.lowercased()
            if lowerText.contains(query.lowercased()) {
                lexical += 4
            }
            if terms.contains(where: { paragraph.section.lowercased().contains($0) }) {
                lexical += 1.5
            }

            var semantic = 0.0
            if let queryVector,
               let paragraphVector = embedding?.vector(for: String(paragraph.text.prefix(1200))) {
                semantic = max(0, cosine(queryVector, paragraphVector))
            }
            raw.append((paragraph, lexical, semantic, Array(Set(matches)).sorted()))
        }

        let maxLexical = raw.map(\.1).max() ?? 1
        return raw
            .map { paragraph, lexical, semantic, matches in
                let lexicalNormalized = maxLexical > 0 ? lexical / maxLexical : 0
                let score = lexicalNormalized * 0.72 + semantic * 0.28
                return PassageHit(
                    id: paragraph.id,
                    paragraph: paragraph,
                    score: score,
                    matchedTerms: matches
                )
            }
            .filter { $0.score > 0.08 }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    private static func tokenize(_ value: String) -> [String] {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
    }

    private static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0
        var leftMagnitude = 0.0
        var rightMagnitude = 0.0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            leftMagnitude += lhs[index] * lhs[index]
            rightMagnitude += rhs[index] * rhs[index]
        }
        let denominator = sqrt(leftMagnitude) * sqrt(rightMagnitude)
        return denominator == 0 ? 0 : dot / denominator
    }
}
