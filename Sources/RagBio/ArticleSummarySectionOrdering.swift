import Foundation

enum ArticleSummarySectionOrdering {
    static func reviewUseFirst(_ note: String) -> String {
        let lines = note.components(separatedBy: "\n")
        let headingIndices = lines.indices.filter {
            lines[$0].range(of: #"^\s*\d+\.\s"#, options: .regularExpression) != nil
        }
        guard let firstHeading = headingIndices.first else { return note }

        let sections = headingIndices.enumerated().map { offset, start in
            let end = offset + 1 < headingIndices.count ? headingIndices[offset + 1] : lines.count
            return Array(lines[start..<end])
        }
        guard let reviewUseIndex = sections.firstIndex(where: { section in
            section.first?.localizedCaseInsensitiveContains("How I can use this paper in my review") == true
        }), reviewUseIndex != 0 else { return note }

        var reordered = [sections[reviewUseIndex]]
        reordered.append(contentsOf: sections.enumerated().compactMap { index, section in
            index == reviewUseIndex ? nil : section
        })

        let renumbered = reordered.enumerated().map { index, section -> [String] in
            guard let heading = section.first else { return section }
            let updatedHeading = heading.replacingOccurrences(
                of: #"^(\s*)\d+\."#,
                with: "$1\(index + 1).",
                options: .regularExpression
            )
            return [updatedHeading] + section.dropFirst()
        }

        return (Array(lines[..<firstHeading]) + renumbered.flatMap { $0 })
            .joined(separator: "\n")
    }
}
