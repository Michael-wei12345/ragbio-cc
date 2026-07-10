import Foundation

enum OpenAlexQueryNormalizer {
    static func normalize(_ rawValue: String) -> String {
        let cleaned = rawValue
            .replacingOccurrences(
                of: #"(?i)\b(AND|OR|NOT)\b"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\b(title|abstract|author|journal|year|doi)\s*:"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[()\[\]{}"“”‘’]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var terms = cleaned
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        terms.append(contentsOf: expansionTerms(for: cleaned))

        return uniquedTerms(terms)
            .prefix(maxSearchTerms)
            .joined(separator: " ")
    }

    private static let maxSearchTerms = 40

    private enum MatchMode {
        case any
        case all
    }

    private struct SynonymRule {
        let triggers: [String]
        let expansions: [String]
        var mode: MatchMode = .any
    }

    private static let synonymRules: [SynonymRule] = [
        // Clinical concepts and MeSH-like subject headings.
        .init(
            triggers: ["gi", "gastrointestinal"],
            expansions: ["gastrointestinal", "digestive", "intestinal"]
        ),
        .init(
            triggers: ["gastrointestinal symptom", "gi symptom", "digestive symptom"],
            expansions: ["GI symptoms", "gastrointestinal symptoms", "digestive symptoms"]
        ),
        .init(
            triggers: ["asd", "autism", "autistic"],
            expansions: ["autism spectrum disorder", "autistic"]
        ),
        .init(
            triggers: ["camouflage", "camouflaging", "masking"],
            expansions: ["social camouflaging", "masking", "compensation"]
        ),
        .init(
            triggers: ["lung cancer", "nsclc", "non-small cell lung cancer"],
            expansions: ["lung cancer", "NSCLC", "non-small cell lung cancer", "pulmonary neoplasm"]
        ),
        .init(
            triggers: ["targeted therapy", "targeted treatment"],
            expansions: ["targeted therapy", "precision oncology", "molecular targeted therapy"]
        ),
        .init(
            triggers: ["inflammatory bowel disease", "ibd"],
            expansions: ["inflammatory bowel disease", "Crohn disease", "ulcerative colitis", "IBD"]
        ),
        .init(
            triggers: ["irritable bowel syndrome", "ibs"],
            expansions: ["irritable bowel syndrome", "IBS", "functional gastrointestinal disorder"]
        ),
        .init(
            triggers: ["type 2 diabetes", "t2d", "t2dm"],
            expansions: ["type 2 diabetes", "T2D", "T2DM", "diabetes mellitus"]
        ),
        .init(
            triggers: ["alzheimer", "alzheimer disease"],
            expansions: ["Alzheimer disease", "dementia", "neurodegenerative"]
        ),
        .init(
            triggers: ["parkinson", "parkinson disease"],
            expansions: ["Parkinson disease", "parkinsonism", "neurodegenerative"]
        ),
        .init(
            triggers: ["myocardial infarction", "heart attack"],
            expansions: ["myocardial infarction", "heart attack", "acute coronary syndrome"]
        ),

        // Drug and medication terminology.
        .init(
            triggers: ["ndc", "national drug code"],
            expansions: ["NDC", "National Drug Code", "drug codes", "prescription claims", "RxNorm"]
        ),
        .init(
            triggers: ["adverse drug event", "ade", "adverse event"],
            expansions: ["adverse drug event", "adverse drug reaction", "ADE", "ADR", "pharmacovigilance"]
        ),
        .init(
            triggers: ["opioid", "opioids"],
            expansions: ["opioid", "opiate", "morphine", "oxycodone", "hydrocodone"]
        ),
        .init(
            triggers: ["nsaid", "nsaids", "non-steroidal anti-inflammatory"],
            expansions: ["NSAID", "nonsteroidal anti-inflammatory", "ibuprofen", "naproxen"]
        ),
        .init(
            triggers: ["ppi", "proton pump inhibitor"],
            expansions: ["proton pump inhibitor", "PPI", "omeprazole", "pantoprazole"]
        ),
        .init(
            triggers: ["acetaminophen", "paracetamol", "tylenol"],
            expansions: ["acetaminophen", "paracetamol", "Tylenol"]
        ),
        .init(
            triggers: ["glp-1", "glp1", "semaglutide"],
            expansions: ["GLP-1 receptor agonist", "semaglutide", "liraglutide", "tirzepatide"]
        ),

        // Healthcare databases, coding systems, and common research infrastructure.
        .init(
            triggers: ["ehr", "emr", "electronic health record", "electronic medical record"],
            expansions: ["electronic health records", "EHR", "EMR", "clinical records"]
        ),
        .init(
            triggers: ["claims", "claim database", "administrative data"],
            expansions: ["claims database", "administrative claims", "insurance claims"]
        ),
        .init(
            triggers: ["faers", "aers"],
            expansions: ["FAERS", "FDA Adverse Event Reporting System", "pharmacovigilance"]
        ),
        .init(
            triggers: ["omop"],
            expansions: ["OMOP", "common data model", "observational medical outcomes partnership"]
        ),
        .init(
            triggers: ["icd", "diagnosis code"],
            expansions: ["ICD", "diagnosis codes", "International Classification of Diseases"]
        ),
        .init(
            triggers: ["cpt", "procedure code"],
            expansions: ["CPT", "procedure codes", "Current Procedural Terminology"]
        ),
        .init(
            triggers: ["meddra"],
            expansions: ["MedDRA", "medical dictionary for regulatory activities", "adverse events"]
        ),
        .init(
            triggers: ["mesh"],
            expansions: ["MeSH", "medical subject headings", "PubMed indexing"]
        ),

        // Population and demographic terms.
        .init(
            triggers: ["child", "children", "pediatric", "paediatric"],
            expansions: ["children", "pediatric", "paediatric"]
        ),
        .init(
            triggers: ["girl", "girls", "female", "women"],
            expansions: ["female", "girls", "women", "sex differences", "gender differences"]
        ),
        .init(
            triggers: ["older adult", "elderly", "veteran", "veterans"],
            expansions: ["older adults", "elderly", "veterans", "geriatric"]
        )
    ]

    private static func expansionTerms(for cleaned: String) -> [String] {
        synonymRules
            .filter { rule in
                switch rule.mode {
                case .any:
                    return rule.triggers.contains { containsTrigger($0, in: cleaned) }
                case .all:
                    return rule.triggers.allSatisfy { containsTrigger($0, in: cleaned) }
                }
            }
            .flatMap(\.expansions)
            .flatMap(splitExpansion)
    }

    private static func splitExpansion(_ value: String) -> [String] {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
    }

    private static func containsTrigger(_ trigger: String, in value: String) -> Bool {
        let normalizedTrigger = trigger
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTrigger.isEmpty else { return false }

        if normalizedTrigger.contains(" ") || normalizedTrigger.contains("-") {
            return value.lowercased().range(
                of: #"(?<![a-z0-9])\#(NSRegularExpression.escapedPattern(for: normalizedTrigger))(?![a-z0-9])"#,
                options: .regularExpression
            ) != nil
        }
        return containsWord(normalizedTrigger, in: " \(value.lowercased()) ")
    }

    private static func containsWord(_ word: String, in paddedLowerValue: String) -> Bool {
        paddedLowerValue.range(
            of: #"(?<![a-z0-9])\#(NSRegularExpression.escapedPattern(for: word))(?![a-z0-9])"#,
            options: .regularExpression
        ) != nil
    }

    private static func uniquedTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var values: [String] = []
        for term in terms {
            let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            let key = clean.lowercased()
            guard seen.insert(key).inserted else { continue }
            values.append(clean)
        }
        return values
    }
}
