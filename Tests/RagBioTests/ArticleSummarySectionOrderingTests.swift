import Testing
@testable import RagBio

@Suite struct ArticleSummarySectionOrderingTests {
    @Test func movesReviewUseSectionFirstAndRenumbersAllSections() {
        let note = """
        Screening verdict: Include as primary evidence — Relevant trial
        1. One-line takeaway:
        Takeaway
        2. Study type and role in my review:
        RCT
        3. PICO / PECO:
        PICO
        4. Methods that matter:
        Methods
        5. Main biological findings:
        Findings
        6. Limitations and confounders:
        Limitations
        7. How I can use this paper in my review:
        Use this evidence
        """

        let reordered = ArticleSummarySectionOrdering.reviewUseFirst(note)

        #expect(reordered.contains("1. How I can use this paper in my review:\nUse this evidence"))
        #expect(reordered.contains("2. One-line takeaway:\nTakeaway"))
        #expect(reordered.contains("7. Limitations and confounders:\nLimitations"))
        #expect(!reordered.contains("7. How I can use this paper in my review:"))
    }

    @Test func leavesAlreadyUpdatedSummaryUnchanged() {
        let note = """
        Screening verdict: Maybe — Check full text
        1. How I can use this paper in my review:
        Background only
        2. One-line takeaway:
        Takeaway
        """

        #expect(ArticleSummarySectionOrdering.reviewUseFirst(note) == note)
    }
}
