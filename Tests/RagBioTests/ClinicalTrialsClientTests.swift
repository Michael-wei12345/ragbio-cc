import Foundation
import Testing
@testable import RagBio

@Suite struct ClinicalTrialsClientTests {
    @Test func registryRecordBecomesEvidenceCandidateAndStudyFamilyAnchor() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClinicalTrialsURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let works = try await ClinicalTrialsClient(session: session).search(
            query: "HER2 trastuzumab",
            pageSize: 10
        )

        let work = try #require(works.first)
        #expect(work.id == "https://clinicaltrials.gov/study/NCT01234567")
        #expect(work.venue == "ClinicalTrials.gov")
        #expect(work.abstractText?.contains("Disease-free survival") == true)
        #expect(StudyFamilyIdentifier.identify(work: work) == "registry:NCT01234567")
        #expect(
            LocalEvidenceCardBuilder.make(
                work: work,
                profile: nil,
                abstract: work.abstractText,
                passages: [],
                hasFullText: false
            ).role == .registry
        )
    }
}

private final class ClinicalTrialsURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let json = #"{"studies":[{"protocolSection":{"identificationModule":{"nctId":"NCT01234567","briefTitle":"HER2 adjuvant trial","officialTitle":"Randomized HER2 adjuvant trastuzumab trial"},"statusModule":{"overallStatus":"COMPLETED","startDateStruct":{"date":"2018-02-01"}},"sponsorCollaboratorsModule":{"leadSponsor":{"name":"Example Sponsor"}},"descriptionModule":{"briefSummary":"A randomized study in early HER2-positive breast cancer."},"conditionsModule":{"conditions":["HER2-positive breast cancer"]},"designModule":{"studyType":"INTERVENTIONAL","phases":["PHASE3"],"enrollmentInfo":{"count":500}},"armsInterventionsModule":{"interventions":[{"name":"Trastuzumab"}]},"outcomesModule":{"primaryOutcomes":[{"measure":"Disease-free survival"}]}}}]}"#
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
