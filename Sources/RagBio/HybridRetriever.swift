import Foundation
import NaturalLanguage

struct HybridRetrievalQuery: @unchecked Sendable {
    let text: String
    let terms: [String]
    let vector: [Double]?
}

struct HybridPassageSearchResult {
    let hits: [PassageHit]
    let cachedEmbeddingCount: Int
    let generatedEmbeddingCount: Int
}

enum HybridRetriever {
    static let maximumSemanticCandidates = 56
    static let maximumNewEmbeddingsPerDocument = 12
    static let evidencePassageLimit = 6

    static func prepare(query: String) -> HybridRetrievalQuery {
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        return HybridRetrievalQuery(
            text: query,
            terms: tokenize(query).uniqued(),
            vector: embedding?.vector(for: query)
        )
    }

    static func search(
        query: String,
        paragraphs: [FullTextParagraph],
        limit: Int = 20
    ) -> [PassageHit] {
        search(preparedQuery: prepare(query: query), paragraphs: paragraphs, limit: limit)
    }

    static func search(
        preparedQuery: HybridRetrievalQuery,
        paragraphs: [FullTextParagraph],
        limit: Int = 20
    ) -> [PassageHit] {
        let terms = preparedQuery.terms
        guard !terms.isEmpty, !paragraphs.isEmpty else { return [] }

        let tokenized = paragraphs.map { paragraph in
            let tokens = tokenize(paragraph.text)
            return (
                paragraph: paragraph,
                tokenCounts: Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +),
                tokenSet: Set(tokens)
            )
        }
        var documentFrequency = Dictionary(uniqueKeysWithValues: terms.map { ($0, 0) })
        for item in tokenized {
            for term in terms where item.tokenSet.contains(term) {
                documentFrequency[term, default: 0] += 1
            }
        }

        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        var lexicalRows: [(FullTextParagraph, Double, [String])] = []

        for item in tokenized {
            let paragraph = item.paragraph
            var lexical = 0.0
            var matches: [String] = []

            for term in terms {
                guard let frequency = item.tokenCounts[term], frequency > 0 else { continue }
                matches.append(term)
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log((Double(paragraphs.count) + 1) / (df + 1)) + 1
                lexical += (1 + log(Double(frequency))) * idf
            }

            let lowerText = paragraph.text.lowercased()
            if lowerText.contains(preparedQuery.text.lowercased()) {
                lexical += 4
            }
            if terms.contains(where: { paragraph.section.lowercased().contains($0) }) {
                lexical += 1.5
            }

            lexicalRows.append((paragraph, lexical, Array(Set(matches)).sorted()))
        }

        let candidateIndices = semanticCandidateIndices(lexicalRows)
        let maxLexical = lexicalRows.map(\.1).max() ?? 1
        let ranked = candidateIndices.compactMap { index -> PassageHit? in
                let (paragraph, lexical, matches) = lexicalRows[index]
                var semantic = 0.0
                if let queryVector = preparedQuery.vector,
                   let paragraphVector = embedding?.vector(
                    for: String(paragraph.text.prefix(1200))
                   ) {
                    semantic = max(0, cosine(queryVector, paragraphVector))
                }
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
        return selectDiverse(ranked, limit: limit)
    }

    static func searchCached(
        preparedQuery: HybridRetrievalQuery,
        workID: String,
        paragraphs: [FullTextParagraph],
        limit: Int = evidencePassageLimit,
        maximumNewEmbeddings: Int = maximumNewEmbeddingsPerDocument,
        cache: ParagraphEmbeddingCache = .shared
    ) async -> HybridPassageSearchResult {
        let terms = preparedQuery.terms
        guard !terms.isEmpty, !paragraphs.isEmpty else {
            return HybridPassageSearchResult(
                hits: [],
                cachedEmbeddingCount: 0,
                generatedEmbeddingCount: 0
            )
        }

        let rows = lexicalRows(preparedQuery: preparedQuery, paragraphs: paragraphs)
        let candidateIndices = semanticCandidateIndices(rows)
        let generationIndices = embeddingGenerationCandidateIndices(
            rows,
            candidateIndices: candidateIndices
        )
        let candidateIDs = Set(candidateIndices.map { rows[$0].0.id })
        let embedding = NLEmbedding.sentenceEmbedding(for: .english)
        let dimension = embedding?.dimension ?? 0
        let modelSignature = "apple-natural-language-\(dimension)-\(ProcessInfo.processInfo.operatingSystemVersionString)"
        let fingerprint = ParagraphEmbeddingCache.contentFingerprint(paragraphs: paragraphs)
        var vectors = await cache.vectors(
            workID: workID,
            contentFingerprint: fingerprint,
            modelSignature: modelSignature,
            dimension: dimension,
            paragraphIDs: candidateIDs
        )
        var generated: [String: [Double]] = [:]
        let generationLimit = max(0, min(
            maximumNewEmbeddings,
            maximumNewEmbeddingsPerDocument
        ))
        if dimension > 0, generationLimit > 0 {
            for index in generationIndices where generated.count < generationLimit {
                let paragraphID = rows[index].0.id
                guard vectors[paragraphID] == nil else { continue }
                try? Task.checkCancellation()
                guard !Task.isCancelled else {
                    return HybridPassageSearchResult(
                        hits: [],
                        cachedEmbeddingCount: vectors.count,
                        generatedEmbeddingCount: generated.count
                    )
                }
                let paragraph = rows[index].0
                if let vector = embedding?.vector(for: String(paragraph.text.prefix(1200))) {
                    vectors[paragraphID] = vector
                    generated[paragraphID] = vector
                }
            }
        }
        await cache.merge(
            generated,
            workID: workID,
            contentFingerprint: fingerprint,
            modelSignature: modelSignature,
            dimension: dimension
        )

        let maxLexical = rows.map(\.1).max() ?? 1
        let ranked = candidateIndices.map { index -> PassageHit in
            let (paragraph, lexical, matches) = rows[index]
            let semantic: Double
            if let queryVector = preparedQuery.vector,
               let paragraphVector = vectors[paragraph.id] {
                semantic = max(0, cosine(queryVector, paragraphVector))
            } else {
                semantic = 0
            }
            let lexicalNormalized = maxLexical > 0 ? lexical / maxLexical : 0
            return PassageHit(
                id: paragraph.id,
                paragraph: paragraph,
                score: lexicalNormalized * 0.72 + semantic * 0.28,
                matchedTerms: matches
            )
        }
        .sorted { $0.score > $1.score }
        return HybridPassageSearchResult(
            hits: selectEvidenceDiverse(ranked, limit: limit),
            cachedEmbeddingCount: vectors.count - generated.count,
            generatedEmbeddingCount: generated.count
        )
    }

    private static func lexicalRows(
        preparedQuery: HybridRetrievalQuery,
        paragraphs: [FullTextParagraph]
    ) -> [(FullTextParagraph, Double, [String])] {
        let terms = preparedQuery.terms
        let tokenized = paragraphs.map { paragraph in
            let tokens = tokenize(paragraph.text)
            return (
                paragraph: paragraph,
                tokenCounts: Dictionary(tokens.map { ($0, 1) }, uniquingKeysWith: +),
                tokenSet: Set(tokens)
            )
        }
        var documentFrequency = Dictionary(uniqueKeysWithValues: terms.map { ($0, 0) })
        for item in tokenized {
            for term in terms where item.tokenSet.contains(term) {
                documentFrequency[term, default: 0] += 1
            }
        }
        return tokenized.map { item in
            let paragraph = item.paragraph
            var lexical = 0.0
            var matches: [String] = []
            for term in terms {
                guard let frequency = item.tokenCounts[term], frequency > 0 else { continue }
                matches.append(term)
                let df = Double(documentFrequency[term] ?? 0)
                let idf = log((Double(paragraphs.count) + 1) / (df + 1)) + 1
                lexical += (1 + log(Double(frequency))) * idf
            }
            let lowerText = paragraph.text.lowercased()
            if lowerText.contains(preparedQuery.text.lowercased()) { lexical += 4 }
            if terms.contains(where: { paragraph.section.lowercased().contains($0) }) {
                lexical += 1.5
            }
            return (paragraph, lexical, Array(Set(matches)).sorted())
        }
    }

    private static func semanticCandidateIndices(
        _ rows: [(FullTextParagraph, Double, [String])]
    ) -> [Int] {
        guard !rows.isEmpty else { return [] }
        var selected: [Int] = []
        var seen = Set<Int>()
        func add(_ index: Int) {
            guard rows.indices.contains(index), seen.insert(index).inserted else { return }
            selected.append(index)
        }

        for index in rows.indices.sorted(by: { rows[$0].1 > rows[$1].1 }).prefix(36) {
            add(index)
        }
        for kind in ["methods", "results", "discussion", "abstract"] {
            let sectionIndices = rows.indices
                .filter { sectionKind(rows[$0].0) == kind }
                .sorted { rows[$0].1 > rows[$1].1 }
            for index in sectionIndices.prefix(4) { add(index) }
        }
        let remaining = max(0, maximumSemanticCandidates - selected.count)
        if remaining > 0 {
            let step = max(1, rows.count / remaining)
            for index in stride(from: 0, to: rows.count, by: step) {
                add(index)
                if selected.count >= maximumSemanticCandidates { break }
            }
        }
        return Array(selected.prefix(maximumSemanticCandidates))
    }

    static func embeddingGenerationCandidateIndices(
        _ rows: [(FullTextParagraph, Double, [String])],
        candidateIndices: [Int]
    ) -> [Int] {
        var ordered: [Int] = []
        var seen = Set<Int>()
        func add(_ index: Int) {
            guard rows.indices.contains(index), seen.insert(index).inserted else { return }
            ordered.append(index)
        }

        let sectionQuotas = [
            ("abstract", 1),
            ("methods", 2),
            ("results", 2),
            ("discussion", 1)
        ]
        for (kind, quota) in sectionQuotas {
            let matching = candidateIndices
                .filter { sectionKind(rows[$0].0) == kind }
                .sorted { rows[$0].1 > rows[$1].1 }
            for index in matching.prefix(quota) { add(index) }
        }
        for index in candidateIndices.sorted(by: { rows[$0].1 > rows[$1].1 }) {
            add(index)
        }
        return ordered
    }

    private static func selectDiverse(_ ranked: [PassageHit], limit: Int) -> [PassageHit] {
        guard limit > 0, let first = ranked.first else { return [] }
        var selected = [first]
        var selectedIDs: Set<FullTextParagraph.ID> = [first.paragraph.id]
        var sectionKinds: Set<String> = [sectionKind(first.paragraph)]

        for hit in ranked.dropFirst() where selected.count < limit {
            let kind = sectionKind(hit.paragraph)
            guard !sectionKinds.contains(kind) else { continue }
            selected.append(hit)
            selectedIDs.insert(hit.paragraph.id)
            sectionKinds.insert(kind)
        }
        for hit in ranked where selected.count < limit && !selectedIDs.contains(hit.paragraph.id) {
            selected.append(hit)
            selectedIDs.insert(hit.paragraph.id)
        }
        return selected
    }

    static func selectEvidenceDiverse(_ ranked: [PassageHit], limit: Int) -> [PassageHit] {
        guard limit > 0 else { return [] }
        var selected: [PassageHit] = []
        var selectedIDs = Set<FullTextParagraph.ID>()
        func add(_ hit: PassageHit) {
            guard selected.count < limit,
                  selectedIDs.insert(hit.paragraph.id).inserted else { return }
            selected.append(hit)
        }

        for kind in ["abstract", "methods", "results", "discussion"] {
            if let hit = ranked.first(where: {
                sectionKind($0.paragraph) == kind
            }) {
                add(hit)
            }
        }
        for hit in ranked { add(hit) }
        return selected
    }

    static func sectionKind(_ paragraph: FullTextParagraph) -> String {
        let explicit = sectionKind(paragraph.section)
        guard explicit == "other" else { return explicit }
        return sectionKind(String(paragraph.text.prefix(180)))
    }

    static func sectionKind(_ section: String) -> String {
        let value = section.lowercased()
        let markers: [(kind: String, terms: [String])] = [
            ("abstract", ["abstract", "summary"]),
            ("methods", ["method", "design", "patient", "participant", "population"]),
            ("results", ["result", "outcome", "finding"]),
            ("discussion", ["discussion", "conclusion"])
        ]
        return markers.compactMap { marker -> (String, String.Index)? in
            marker.terms.compactMap { value.range(of: $0)?.lowerBound }
                .min()
                .map { (marker.kind, $0) }
        }
        .min { $0.1 < $1.1 }?
        .0 ?? "other"
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
