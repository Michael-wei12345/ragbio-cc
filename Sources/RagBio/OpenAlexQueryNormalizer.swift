import Foundation

/// OpenAlex `search` works best with short natural-language concepts. Query expansion belongs in
/// the source-specific search plan; this layer only removes syntax that OpenAlex would interpret as
/// literal noise. It intentionally does not append a global synonym soup.
enum OpenAlexQueryNormalizer {
    static func normalize(_ rawValue: String) -> String {
        let cleaned = rawValue
            .replacingOccurrences(
                of: #"(?i)\b(AND|OR|NOT)\b"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?i)\b(title|abstract|author|journal|year|doi|tiab|mesh)\s*[:\[]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"[()\[\]{}\"“”‘’]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var seen = Set<String>()
        return cleaned.split(separator: " ")
            .map(String.init)
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(24)
            .joined(separator: " ")
    }
}
