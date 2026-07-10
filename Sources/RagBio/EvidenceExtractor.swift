import Foundation

enum EvidenceExtractor {
    static func extract(query: String, works: [Work], maximum: Int = 8) -> [Evidence] {
        let terms = normalizedTerms(from: query)
        var candidates: [(work: Work, sentence: String, score: Int, workIndex: Int)] = []

        for (workIndex, work) in works.enumerated() {
            guard let abstract = work.abstractText else { continue }
            for sentence in sentences(from: abstract) {
                let normalizedSentence = sentence.lowercased()
                let matches = terms.reduce(into: 0) { total, term in
                    if normalizedSentence.localizedCaseInsensitiveContains(term) {
                        total += 1
                    }
                }
                let score = matches * 100 - workIndex
                if matches > 0 || terms.isEmpty {
                    candidates.append((work, sentence, score, workIndex))
                }
            }
        }

        if candidates.isEmpty {
            for (workIndex, work) in works.enumerated() {
                guard let abstract = work.abstractText,
                      let first = sentences(from: abstract).first else { continue }
                candidates.append((work, first, -workIndex, workIndex))
            }
        }

        var seenWorks = Set<String>()
        var selected: [(work: Work, sentence: String, score: Int)] = []
        for candidate in candidates.sorted(by: { lhs, rhs in
            if lhs.score == rhs.score { return lhs.workIndex < rhs.workIndex }
            return lhs.score > rhs.score
        }) {
            guard !seenWorks.contains(candidate.work.id) else { continue }
            seenWorks.insert(candidate.work.id)
            selected.append((candidate.work, candidate.sentence, candidate.score))
            if selected.count == maximum { break }
        }

        return selected.enumerated().map { index, item in
            Evidence(
                work: item.work,
                sentence: item.sentence,
                score: item.score,
                citationNumber: index + 1
            )
        }
    }

    static func sentences(from text: String) -> [String] {
        var ranges: [Range<String.Index>] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            ranges.append(range)
        }

        let values = ranges.map {
            String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        return values.isEmpty ? [text] : values
    }

    private static func normalizedTerms(from query: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        return query.lowercased()
            .components(separatedBy: separators)
            .filter { $0.count >= 2 }
    }
}
