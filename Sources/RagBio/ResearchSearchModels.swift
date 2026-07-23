import Foundation

enum ReviewQuestionType: String, Codable, CaseIterable, Equatable {
    case intervention
    case diagnosis
    case prognosis
    case etiology
    case prevalence
    case qualitative
    case other
}

struct ResearchQuestionProfile: Codable, Equatable {
    var questionType: ReviewQuestionType
    var population: [String]
    var interventionOrExposure: [String]
    var comparator: [String]
    var outcomes: [String]
    var context: [String]
    var preferredStudyDesigns: [String]

    enum CodingKeys: String, CodingKey {
        case questionType = "question_type"
        case population
        case interventionOrExposure = "intervention_or_exposure"
        case comparator, outcomes, context
        case preferredStudyDesigns = "preferred_study_designs"
    }

    init(
        questionType: ReviewQuestionType,
        population: [String],
        interventionOrExposure: [String],
        comparator: [String],
        outcomes: [String],
        context: [String],
        preferredStudyDesigns: [String]
    ) {
        self.questionType = questionType
        self.population = population
        self.interventionOrExposure = interventionOrExposure
        self.comparator = comparator
        self.outcomes = outcomes
        self.context = context
        self.preferredStudyDesigns = preferredStudyDesigns
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try values.decodeIfPresent(String.self, forKey: .questionType) ?? "other"
        questionType = ReviewQuestionType(rawValue: rawType.lowercased()) ?? .other

        func strings(_ key: CodingKeys) -> [String] {
            if let array = try? values.decode([String].self, forKey: key) { return array }
            if let value = try? values.decode(String.self, forKey: key) { return [value] }
            return []
        }
        population = strings(.population)
        interventionOrExposure = strings(.interventionOrExposure)
        comparator = strings(.comparator)
        outcomes = strings(.outcomes)
        context = strings(.context)
        preferredStudyDesigns = strings(.preferredStudyDesigns)
    }

    static let empty = ResearchQuestionProfile(
        questionType: .other,
        population: [],
        interventionOrExposure: [],
        comparator: [],
        outcomes: [],
        context: [],
        preferredStudyDesigns: []
    )

    var retrievalTerms: [String] {
        Self.unique(
            population + interventionOrExposure + comparator + outcomes + context
        )
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            let key = clean.lowercased()
            return seen.insert(key).inserted ? clean : nil
        }
    }
}

enum DiscoverySource: String, Codable, Hashable, CaseIterable {
    case openAlex
    case pubMed
    case clinicalTrials
    case citation
}

struct SearchCandidateHit: Hashable {
    let work: Work
    let source: DiscoverySource
    let lane: Int
    let rank: Int
}

struct FusedCandidate: Hashable {
    let work: Work
    let discoveryScore: Double
    let sources: Set<DiscoverySource>
    let firstSeenOrder: Int
}

enum CandidateTriageDisposition: String, Codable, CaseIterable {
    /// The title/abstract directly supports keeping this record for evidence preparation.
    case likely
    /// Evidence is missing or insufficient. Unclear records are protected from automatic removal.
    case unclear
    /// A review, guideline, protocol, or registry record that can support context or citation chasing.
    case background
    /// A high-confidence mismatch on a core eligibility concept.
    case explicitMismatch = "explicit_mismatch"
}

struct AICandidateTriageOutput: Decodable, Equatable {
    let index: Int
    let disposition: CandidateTriageDisposition
    let directness: Int
    let confidence: EvidenceConfidence

    func withIndex(_ index: Int) -> Self {
        Self(
            index: index,
            disposition: disposition,
            directness: directness,
            confidence: confidence
        )
    }
}

struct AICandidateTriageResponse: Decodable {
    let decisions: [AICandidateTriageOutput]
}

enum CandidatePoolSelector {
    /// Selects the bounded evidence-preparation set. This is deliberately not the final ranking:
    /// it only keeps likely and uncertain records ahead of clear mismatches.
    static func select(
        from candidates: [FusedCandidate],
        decisions: [Int: AICandidateTriageOutput],
        profile: ResearchQuestionProfile?,
        limit: Int,
        unclearReserve: Int = 90,
        backgroundReserve: Int = 12
    ) -> [Work] {
        guard limit > 0 else { return [] }

        struct Row {
            let candidate: FusedCandidate
            let disposition: CandidateTriageDisposition
            let directness: Int
            let localPriority: Double
        }

        let rows = candidates.enumerated().map { index, candidate -> Row in
            let decision = decisions[index]
            let disposition = protectedDisposition(
                decision,
                for: candidate.work
            )
            return Row(
                candidate: candidate,
                disposition: disposition,
                directness: min(3, max(0, decision?.directness ?? 0)),
                localPriority: CandidateDiscoveryScorer.score(
                    work: candidate.work,
                    profile: profile
                )
            )
        }

        func isHigherPriority(_ lhs: Row, than rhs: Row) -> Bool {
            if lhs.directness != rhs.directness {
                return lhs.directness > rhs.directness
            }
            if lhs.localPriority != rhs.localPriority {
                return lhs.localPriority > rhs.localPriority
            }
            if lhs.candidate.sources.count != rhs.candidate.sources.count {
                return lhs.candidate.sources.count > rhs.candidate.sources.count
            }
            if lhs.candidate.discoveryScore != rhs.candidate.discoveryScore {
                return lhs.candidate.discoveryScore > rhs.candidate.discoveryScore
            }
            return lhs.candidate.firstSeenOrder < rhs.candidate.firstSeenOrder
        }

        func ordered(_ disposition: CandidateTriageDisposition) -> [Row] {
            rows.filter { $0.disposition == disposition }
                .sorted { isHigherPriority($0, than: $1) }
        }

        let likely = ordered(.likely)
        let unclear = ordered(.unclear)
        let background = ordered(.background)
        let protectedBackground = min(limit, min(backgroundReserve, background.count))
        let protectedUnclear = min(
            max(0, limit - protectedBackground),
            min(unclearReserve, unclear.count)
        )
        let initialLikelyLimit = max(0, limit - protectedUnclear - protectedBackground)

        var selected = Array(likely.prefix(initialLikelyLimit))
        selected += unclear.prefix(protectedUnclear)
        selected += background.prefix(protectedBackground)

        if selected.count < limit {
            let selectedIDs = Set(selected.map(\.candidate.work.id))
            let remaining = (likely + unclear + background)
                .filter { !selectedIDs.contains($0.candidate.work.id) }
                .sorted { isHigherPriority($0, than: $1) }
            selected += remaining.prefix(limit - selected.count)
        }
        return selected.prefix(limit).map(\.candidate.work)
    }

    /// Missing evidence and low-confidence model judgments never become automatic exclusions.
    private static func protectedDisposition(
        _ decision: AICandidateTriageOutput?,
        for work: Work
    ) -> CandidateTriageDisposition {
        if work.abstractText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .unclear
        }
        if work.nonPrimaryPublicationKind != nil {
            return .background
        }
        guard let decision else { return .unclear }
        if decision.disposition == .explicitMismatch, decision.confidence != .high {
            return .unclear
        }
        return decision.disposition
    }
}

enum CandidateDiscoveryScorer {
    /// Cheap title/abstract priority used only to keep the AI triage set bounded. It never applies
    /// the final 5% threshold and never turns missing evidence into a mismatch.
    static func score(work: Work, profile: ResearchQuestionProfile?) -> Double {
        guard let profile else { return 0 }
        let title = normalized(work.title)
        let abstract = normalized(work.abstractText ?? "")
        let titleTokens = Set(tokens(title))
        let abstractTokens = Set(tokens(abstract))
        let groups = [
            profile.population,
            profile.interventionOrExposure,
            profile.comparator,
            profile.outcomes,
            profile.context
        ].filter { !$0.isEmpty }

        var value = 0.0
        for concepts in groups {
            let best = concepts.map { concept -> Double in
                let conceptTokens = Set(tokens(normalized(concept)))
                guard !conceptTokens.isEmpty else { return 0 }
                let titleOverlap = Double(conceptTokens.intersection(titleTokens).count)
                    / Double(conceptTokens.count)
                let abstractOverlap = Double(conceptTokens.intersection(abstractTokens).count)
                    / Double(conceptTokens.count)
                return max(titleOverlap * 1.5, abstractOverlap)
            }.max() ?? 0
            value += best
        }

        let designText = [work.title, work.abstractText ?? "", work.publicationTypes?.joined(separator: " ") ?? ""]
            .joined(separator: " ")
            .lowercased()
        if profile.preferredStudyDesigns.contains(where: {
            let clean = normalized($0)
            return !clean.isEmpty && designText.contains(clean)
        }) {
            value += 1.25
        } else if designText.range(
            of: #"\b(?:randomized|randomised|trial|cohort|case control|prospective|retrospective)\b"#,
            options: .regularExpression
        ) != nil {
            value += 0.6
        }
        return value
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(_ value: String) -> [String] {
        value.split(separator: " ").map(String.init).filter { $0.count >= 2 }
    }
}

enum EvidenceMatch: String, Codable, CaseIterable {
    case match
    case partial
    case mismatch
    case unclear

    var pointsFactor: Double {
        switch self {
        case .match: return 1
        case .partial: return 0.55
        case .mismatch: return 0
        case .unclear: return 0.35
        }
    }
}

enum EvidenceRole: String, Codable, CaseIterable {
    case primary
    case followUp = "follow_up"
    case subgroup
    case safety
    case registry
    case background
    case protocolRecord = "protocol"
    case unclear
}

enum EvidenceConfidence: String, Codable, CaseIterable {
    case high
    case medium
    case low
}

struct StructuredEvidenceCard: Codable, Equatable, Identifiable {
    var id: String { workID }
    let workID: String
    let population: EvidenceMatch
    let interventionOrExposure: EvidenceMatch
    let comparator: EvidenceMatch
    let outcome: EvidenceMatch
    let context: EvidenceMatch
    let role: EvidenceRole
    let reportsEffectEstimate: Bool
    let reportsSampleSize: Bool
    let hasComparatorGroup: Bool
    let reportsFollowUp: Bool
    let uniqueContribution: Bool
    let confidence: EvidenceConfidence
    let studyFamilyID: String?
    let evidenceBasis: String
}

struct AIEvidenceCardOutput: Decodable, Equatable {
    let index: Int
    let population: EvidenceMatch
    let interventionOrExposure: EvidenceMatch
    let comparator: EvidenceMatch
    let outcome: EvidenceMatch
    let context: EvidenceMatch
    let role: EvidenceRole
    let reportsEffectEstimate: Bool
    let reportsSampleSize: Bool
    let hasComparatorGroup: Bool
    let reportsFollowUp: Bool
    let uniqueContribution: Bool

    enum CodingKeys: String, CodingKey {
        case index, population, comparator, outcome, context, role
        case interventionOrExposure = "intervention_or_exposure"
        case reportsEffectEstimate = "reports_effect_estimate"
        case reportsSampleSize = "reports_sample_size"
        case hasComparatorGroup = "has_comparator_group"
        case reportsFollowUp = "reports_follow_up"
        case uniqueContribution = "unique_contribution"
    }

    func withIndex(_ index: Int) -> Self {
        Self(
            index: index,
            population: population,
            interventionOrExposure: interventionOrExposure,
            comparator: comparator,
            outcome: outcome,
            context: context,
            role: role,
            reportsEffectEstimate: reportsEffectEstimate,
            reportsSampleSize: reportsSampleSize,
            hasComparatorGroup: hasComparatorGroup,
            reportsFollowUp: reportsFollowUp,
            uniqueContribution: uniqueContribution
        )
    }
}

struct AIEvidenceCardResponse: Decodable {
    let cards: [AIEvidenceCardOutput]
}

struct AIGlobalScoreOutput: Decodable, Equatable {
    let index: Int
    let score: Int

    func withIndex(_ index: Int) -> Self { Self(index: index, score: score) }
}

struct AIGlobalScoreResponse: Decodable {
    let rankings: [AIGlobalScoreOutput]
}

enum EvidenceUsefulnessScorer {
    static func score(_ card: StructuredEvidenceCard) -> Int {
        var value = 0.0
        value += 12 * card.population.pointsFactor
        value += 12 * card.interventionOrExposure.pointsFactor
        value += 6 * card.comparator.pointsFactor
        value += 10 * card.outcome.pointsFactor
        value += 15 * card.context.pointsFactor

        switch card.role {
        case .primary: value += 20
        case .followUp: value += 18
        case .subgroup: value += 17
        case .safety: value += 15
        case .registry: value += 12
        case .background: value += 7
        case .protocolRecord: value += 5
        case .unclear: value += 8
        }

        if card.reportsEffectEstimate { value += 6 }
        if card.reportsSampleSize { value += 3 }
        if card.hasComparatorGroup { value += 3 }
        if card.reportsFollowUp { value += 3 }
        if card.uniqueContribution { value += 10 }

        // A clear mismatch in a core concept should fall below the visible threshold.
        if card.population == .mismatch || card.interventionOrExposure == .mismatch {
            value = min(value, 4)
        }
        return min(100, max(0, Int(value.rounded())))
    }
}

enum LocalEvidenceCardBuilder {
    static func make(
        work: Work,
        profile: ResearchQuestionProfile?,
        abstract: String?,
        passages: [PassageHit],
        hasFullText: Bool
    ) -> StructuredEvidenceCard {
        let text = ([work.title, abstract ?? ""] + passages.map(\.paragraph.text))
            .joined(separator: " ")
        let normalized = normalize(text)
        let profile = profile ?? .empty
        let role = evidenceRole(for: work, text: normalized)
        let confidence: EvidenceConfidence = hasFullText
            ? .high
            : ((abstract?.isEmpty == false) ? .medium : .low)
        return StructuredEvidenceCard(
            workID: work.id,
            population: match(profile.population, in: normalized),
            interventionOrExposure: match(profile.interventionOrExposure, in: normalized),
            comparator: match(profile.comparator, in: normalized),
            outcome: match(profile.outcomes, in: normalized),
            context: match(profile.context, in: normalized),
            role: role,
            reportsEffectEstimate: contains(
                #"\b(?:hazard ratio|odds ratio|risk ratio|relative risk|mean difference|confidence interval|p\s*[<=>])\b"#,
                in: normalized
            ),
            reportsSampleSize: contains(
                #"\b(?:n\s*=\s*\d+|\d+\s+(?:patients|participants|subjects|cases))\b"#,
                in: normalized
            ),
            hasComparatorGroup: contains(
                #"\b(?:versus|vs\.?|control group|comparator|randomized|randomised)\b"#,
                in: normalized
            ),
            reportsFollowUp: contains(
                #"\b(?:follow[- ]?up|overall survival|disease[- ]free survival|progression[- ]free survival|recurrence)\b"#,
                in: normalized
            ),
            uniqueContribution: role == .followUp || role == .subgroup || role == .safety,
            confidence: confidence,
            studyFamilyID: StudyFamilyIdentifier.identify(work: work, evidenceText: text),
            evidenceBasis: hasFullText ? "full_text" : ((abstract?.isEmpty == false) ? "abstract" : "metadata")
        )
    }

    private static func match(_ concepts: [String], in text: String) -> EvidenceMatch {
        let values = concepts.map(normalize).filter { !$0.isEmpty }
        guard !values.isEmpty else { return .unclear }
        if values.contains(where: { text.contains($0) }) { return .match }
        let textTokens = Set(tokens(text))
        let bestOverlap = values.map { concept -> Double in
            let conceptTokens = Set(tokens(concept))
            guard !conceptTokens.isEmpty else { return 0 }
            return Double(conceptTokens.intersection(textTokens).count) / Double(conceptTokens.count)
        }.max() ?? 0
        return bestOverlap >= 0.5 ? .partial : .unclear
    }

    private static func evidenceRole(for work: Work, text: String) -> EvidenceRole {
        if work.id.lowercased().contains("clinicaltrials.gov") { return .registry }
        if let kind = work.nonPrimaryPublicationKind {
            switch kind {
            case .review, .metaAnalysis, .guideline, .consensus: return .background
            case .studyProtocol: return .protocolRecord
            case .retracted, .editorial, .comment, .letter: return .background
            }
        }
        if contains(#"\b(?:follow[- ]?up|long[- ]term)\b"#, in: text) { return .followUp }
        if contains(#"\b(?:subgroup|subanalysis|subset)\b"#, in: text) { return .subgroup }
        if contains(#"\b(?:safety|adverse event|toxicity)\b"#, in: text) { return .safety }
        let primaryTerms = [
            "randomized", "randomised", "clinical trial", "cohort", "case control",
            "prospective", "retrospective", "participants", "patients"
        ]
        return primaryTerms.contains(where: { text.contains($0) }) ? .primary : .unclear
    }

    private static func contains(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(_ value: String) -> [String] {
        normalize(value).split(separator: " ").map(String.init).filter { $0.count >= 2 }
    }
}

enum StudyFamilyIdentifier {
    static func identify(work: Work, evidenceText: String = "") -> String? {
        let combined = [work.id, work.title, work.abstractText ?? "", evidenceText]
            .joined(separator: " ")
        if let registry = firstMatch(
            in: combined,
            pattern: #"\b(?:NCT\d{8}|ISRCTN\d{6,10}|EUCTR\d{4}-\d{6}-\d{2})\b"#
        ) {
            return "registry:\(registry.uppercased())"
        }

        let stopWords: Set<String> = [
            "HER2", "DNA", "RNA", "RCT", "OS", "DFS", "PFS", "HR", "CI", "FDA",
            "ASCO", "ESMO", "NCCN", "COVID", "MRI", "PET", "CT", "BACKGROUND",
            "OBJECTIVE", "OBJECTIVES", "METHOD", "METHODS", "RESULT", "RESULTS",
            "CONCLUSION", "CONCLUSIONS", "INTRODUCTION", "AIM", "AIMS"
        ]
        let acronymPattern = #"\b[A-Z][A-Z0-9-]{2,14}\b"#
        if let regex = try? NSRegularExpression(pattern: acronymPattern) {
            let range = NSRange(combined.startIndex..<combined.endIndex, in: combined)
            for match in regex.matches(in: combined, range: range) {
                guard let swiftRange = Range(match.range, in: combined) else { continue }
                let token = String(combined[swiftRange])
                if !stopWords.contains(token), token.rangeOfCharacter(from: .decimalDigits) == nil {
                    return "acronym:\(token)"
                }
            }
        }
        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        return String(text[range])
    }
}

enum CandidateFusion {
    private static let rrfConstant = 60.0

    static func fuse(_ hits: [SearchCandidateHit]) -> [FusedCandidate] {
        struct Bucket {
            var work: Work
            var score: Double
            var sources: Set<DiscoverySource>
            var firstSeen: Int
        }

        var buckets: [String: Bucket] = [:]
        var aliases: [String: String] = [:]

        for (order, hit) in hits.enumerated() {
            let keys = identityKeys(for: hit.work)
            let existingKey = keys.compactMap { aliases[$0] }.first
            let canonical = existingKey ?? keys.first ?? "id:\(hit.work.id.lowercased())"
            let contribution = 1.0 / (rrfConstant + Double(max(1, hit.rank)))

            if var bucket = buckets[canonical] {
                bucket.work = richer(bucket.work, hit.work)
                bucket.score += contribution
                bucket.sources.insert(hit.source)
                buckets[canonical] = bucket
            } else {
                buckets[canonical] = Bucket(
                    work: hit.work,
                    score: contribution,
                    sources: [hit.source],
                    firstSeen: order
                )
            }
            for key in keys { aliases[key] = canonical }
        }

        return buckets.values
            .map { bucket in
                let sourceBonus = Double(max(0, bucket.sources.count - 1)) * 0.008
                return FusedCandidate(
                    work: bucket.work,
                    discoveryScore: bucket.score + sourceBonus,
                    sources: bucket.sources,
                    firstSeenOrder: bucket.firstSeen
                )
            }
            .sorted {
                if $0.discoveryScore == $1.discoveryScore {
                    return $0.firstSeenOrder < $1.firstSeenOrder
                }
                return $0.discoveryScore > $1.discoveryScore
            }
    }

    private static func identityKeys(for work: Work) -> [String] {
        var keys: [String] = []
        if let doi = work.normalizedDOI, !doi.isEmpty { keys.append("doi:\(doi)") }
        if let pmid = work.normalizedPMID, !pmid.isEmpty { keys.append("pmid:\(pmid)") }
        let title = work.title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !title.isEmpty { keys.append("title:\(title)") }
        return keys
    }

    private static func richer(_ lhs: Work, _ rhs: Work) -> Work {
        func richness(_ work: Work) -> Int {
            (work.abstractText?.count ?? 0)
                + (work.hasAvailableFullText ? 2_000 : 0)
                + (work.normalizedPMID == nil ? 0 : 500)
                + (work.normalizedDOI == nil ? 0 : 250)
        }
        let prefersRHS = richness(rhs) > richness(lhs)
        let preferred = prefersRHS ? rhs : lhs
        let secondary = prefersRHS ? lhs : rhs
        var locations = preferred.locations
        locations += secondary.locations.filter { !locations.contains($0) }
        var publicationTypes = preferred.publicationTypes ?? []
        publicationTypes += (secondary.publicationTypes ?? []).filter {
            !publicationTypes.contains($0)
        }
        let abstract = [lhs.abstractText, rhs.abstractText]
            .compactMap { $0 }
            .max { $0.count < $1.count }
        let openAccessWork = lhs.isOpenAccess ? lhs : (rhs.isOpenAccess ? rhs : nil)
        return Work(
            id: preferred.id,
            doi: preferred.doi ?? secondary.doi,
            title: preferred.title,
            publicationDate: preferred.publicationDate ?? secondary.publicationDate,
            publicationYear: preferred.publicationYear ?? secondary.publicationYear,
            citedByCount: max(preferred.citedByCount, secondary.citedByCount),
            authorships: preferred.authorships.isEmpty
                ? secondary.authorships
                : preferred.authorships,
            abstractInvertedIndex: nil,
            primaryLocation: preferred.primaryLocation ?? secondary.primaryLocation,
            bestOpenAccessLocation: preferred.bestOpenAccessLocation
                ?? secondary.bestOpenAccessLocation,
            openAccess: openAccessWork?.openAccess
                ?? preferred.openAccess
                ?? secondary.openAccess,
            contentURLs: preferred.contentURLs ?? secondary.contentURLs,
            hasFullText: preferred.hasFullText == true || secondary.hasFullText == true,
            ids: WorkIDs(
                pmid: preferred.ids?.pmid ?? secondary.ids?.pmid,
                pmcid: preferred.ids?.pmcid ?? secondary.ids?.pmcid
            ),
            locations: locations,
            isRetracted: preferred.isRetracted == true || secondary.isRetracted == true,
            type: preferred.type ?? secondary.type,
            publicationTypes: publicationTypes.isEmpty ? nil : publicationTypes,
            language: preferred.language ?? secondary.language,
            abstractPlain: abstract
        )
    }
}
