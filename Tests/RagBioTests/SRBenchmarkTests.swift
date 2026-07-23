import Foundation
import Testing
@testable import RagBio

@Suite
struct SRBenchmarkTests {
    @Test
    func benchmarkManifestsAreAuditableAndCoverMultipleQuestionTypes() throws {
        let manifests = try SRBenchmarkFixtureLoader.loadAll()

        #expect(manifests.count == 10)
        #expect(manifests.flatMap(\.goldStudyFamilies).count == 72)
        #expect(manifests.filter { $0.question.profile.questionType == .intervention }.count == 5)
        #expect(manifests.filter { $0.question.profile.questionType == .diagnosis }.count == 2)
        #expect(manifests.filter { $0.question.profile.questionType == .prognosis }.count == 2)
        #expect(manifests.filter { $0.question.profile.questionType == .etiology }.count == 1)
        #expect(Set(manifests.map(\.id)).count == manifests.count)
        for manifest in manifests {
            #expect(manifest.schemaVersion == 1)
            #expect(!manifest.review.citation.isEmpty)
            #expect(URL(string: manifest.review.sourceURL) != nil)
            #expect(manifest.review.searchCutoff.range(
                of: #"^\d{4}-\d{2}-\d{2}$"#,
                options: .regularExpression
            ) != nil)
            #expect(!manifest.question.naturalLanguageInput.isEmpty)
            #expect(!manifest.question.structuredInput.isEmpty)
            #expect(!manifest.question.eligibilityCriteria.isEmpty)
            #expect(manifest.question.profile.questionType != .other)
            #expect(!manifest.goldStudyFamilies.isEmpty)
            #expect(!manifest.openAlexQueries.isEmpty)
            #expect(!manifest.pubMedQueries.isEmpty)
            #expect(!manifest.clinicalTrialsQueries.isEmpty)
            #expect(Set(manifest.goldStudyFamilies.map(\.id)).count
                == manifest.goldStudyFamilies.count)
            #expect(manifest.prohibitedCitationSeeds.contains {
                $0.matches(manifest.review.identity)
            })
            for family in manifest.goldStudyFamilies {
                #expect(!family.reports.isEmpty)
                #expect(family.reports.allSatisfy {
                    $0.identity.hasStableIdentifier || $0.identity.title != nil
                })
            }
        }
    }

    @Test
    func familyRecallCountsMultipleReportsFromOneTrialOnce() throws {
        let manifest = try #require(
            SRBenchmarkFixtureLoader.loadAll().first {
                $0.id == "pfo-closure-cryptogenic-stroke-2018"
            }
        )
        let records = [
            SRBenchmarkRecord(
                identity: .init(pmid: "23514286"),
                publicationDate: "2013-03-21"
            ),
            SRBenchmarkRecord(
                identity: .init(pmid: "28902590"),
                publicationDate: "2017-09-14"
            )
        ]

        let metrics = SRBenchmarkEvaluator.evaluate(
            manifest: manifest,
            rankedRecords: records
        )

        #expect(metrics.foundFamilyIDs == ["respect"])
        #expect(metrics.familyRecall == 1.0 / 6.0)
    }

    @Test
    func thresholdAuditFindsCriticalFamilyHiddenBelowFive() throws {
        let manifest = try #require(
            SRBenchmarkFixtureLoader.loadAll().first {
                $0.id == "her2-trastuzumab-duration-2020"
            }
        )
        let records = [
            SRBenchmarkRecord(
                identity: .init(pmid: "30219886"),
                publicationDate: "2018-10-01",
                score: 4
            ),
            SRBenchmarkRecord(
                identity: .init(pmid: "29852043"),
                publicationDate: "2018-06-01",
                score: 80
            )
        ]

        let metrics = SRBenchmarkEvaluator.evaluate(
            manifest: manifest,
            rankedRecords: records
        )

        #expect(metrics.familyRecall == 2.0 / 6.0)
        #expect(metrics.thresholdedFamilyRecall == 1.0 / 6.0)
        #expect(metrics.criticalFamiliesBelowThreshold == ["short-her"])
    }

    @Test
    func knownGoldPublishedAfterCutoffIsNotDiscardedByIssueDate() throws {
        let manifest = try #require(
            SRBenchmarkFixtureLoader.loadAll().first {
                $0.id == "intranasal-ketamine-depression-2021"
            }
        )
        let records = [
            SRBenchmarkRecord(
                identity: .init(pmid: "24821196"),
                publicationDate: "2021-01-01"
            )
        ]

        let metrics = SRBenchmarkEvaluator.evaluate(
            manifest: manifest,
            rankedRecords: records
        )

        #expect(metrics.foundFamilyIDs == ["lapidus-2014"])
        #expect(metrics.familyRecall == 1.0 / 6.0)
    }

    @Test
    func blindRunFlagsTargetReviewOnlyWhenUsedAsCitationSeed() throws {
        let manifest = try #require(
            SRBenchmarkFixtureLoader.loadAll().first {
                $0.id == "fmt-ulcerative-colitis-2022"
            }
        )
        let target = SRBenchmarkRecord(
            identity: manifest.review.identity,
            publicationDate: "2022-08-01",
            usedAsCitationSeed: true
        )

        let metrics = SRBenchmarkEvaluator.evaluate(
            manifest: manifest,
            rankedRecords: [target]
        )

        #expect(metrics.prohibitedCitationSeedMatches.count == 1)
    }
}
