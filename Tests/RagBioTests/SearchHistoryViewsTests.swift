import Foundation
import Testing
@testable import RagBio

@Suite struct SearchHistoryViewsTests {
    @Test func emptyQueryKeepsNewestFirstHistoryOrder() {
        let newer = summary(query: "newer", date: 2)
        let older = summary(query: "older", date: 1)

        let visible = SearchHistorySuggestions.filtered(
            [newer, older],
            query: "   "
        )

        #expect(visible.map(\.id) == [newer.id, older.id])
    }

    @Test func typingFiltersLocallyByNormalizedSubstring() {
        let match = summary(query: "Gut   Microbiota Study", date: 2)
        let other = summary(query: "CRISPR methods", date: 1)

        let visible = SearchHistorySuggestions.filtered(
            [match, other],
            query: "  MICROBIOTA   STUDY "
        )

        #expect(visible.map(\.id) == [match.id])
    }

    @Test func submissionRequiresOnlyNonblankInput() {
        #expect(!SearchHistorySuggestions.canSubmit(query: " \n ", isLoading: false))
        #expect(SearchHistorySuggestions.canSubmit(query: "gut", isLoading: true))
        #expect(SearchHistorySuggestions.canSubmit(query: "gut", isLoading: false))
    }

    @Test func articleSummaryStartsOnlyOnAbstractToSummaryTransition() {
        #expect(ArticleSummaryTrigger.shouldGenerate(from: 0, to: 1))
        #expect(!ArticleSummaryTrigger.shouldGenerate(from: 1, to: 1))
        #expect(!ArticleSummaryTrigger.shouldGenerate(from: 1, to: 0))
        #expect(!ArticleSummaryTrigger.shouldGenerate(from: 0, to: 0))
    }

    private func summary(query: String, date: TimeInterval) -> SearchHistorySummary {
        SearchHistorySummary(
            id: UUID(),
            displayQuery: query,
            normalizedQuery: SearchQueryIdentity.normalize(query),
            createdAt: Date(timeIntervalSince1970: date),
            lastSuccessfulSearchAt: Date(timeIntervalSince1970: date),
            paperCount: 1,
            useCount: 0
        )
    }
}
