import Foundation

/// Best-effort discovery of trial registrations. Registry records are candidates and study-family
/// anchors; they are not treated as published outcome reports.
struct ClinicalTrialsClient {
    var session: URLSession = .shared

    enum ClientError: LocalizedError {
        case invalidURL
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "无法构建 ClinicalTrials.gov 请求。"
            case let .badStatus(status): return "ClinicalTrials.gov 请求失败（\(status)）。"
            }
        }
    }

    func search(
        query: String,
        pageSize: Int = 60,
        timeout: TimeInterval = 15,
        maxAttempts: Int = 3
    ) async throws -> [Work] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        var components = URLComponents(string: "https://clinicaltrials.gov/api/v2/studies")
        components?.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "pageSize", value: String(min(1_000, max(1, pageSize)))),
            URLQueryItem(name: "query.term", value: term),
            URLQueryItem(
                name: "fields",
                value: [
                    "NCTId", "BriefTitle", "OfficialTitle", "BriefSummary", "Condition",
                    "InterventionName", "LeadSponsorName", "StudyType", "Phase", "EnrollmentCount",
                    "StartDate", "PrimaryCompletionDate", "OverallStatus", "PrimaryOutcomeMeasure"
                ].joined(separator: "|")
            )
        ]
        guard let url = components?.url else { throw ClientError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("RagBio/0.1 (macOS academic search client)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ClientError.badStatus(-1)
                }
                if (200..<300).contains(http.statusCode) {
                    return try JSONDecoder().decode(Response.self, from: data).studies.map(makeWork)
                }
                let error = ClientError.badStatus(http.statusCode)
                guard [429, 503].contains(http.statusCode), attempt < maxAttempts - 1 else {
                    throw error
                }
                lastError = error
                try await Task.sleep(for: .seconds(Self.retryDelay(http: http, attempt: attempt)))
            } catch let error as URLError where attempt < maxAttempts - 1 {
                lastError = error
                try await Task.sleep(for: .seconds(min(8, 1 << attempt)))
            }
        }
        throw lastError ?? ClientError.badStatus(-1)
    }

    private static func retryDelay(http: HTTPURLResponse, attempt: Int) -> Int {
        if let raw = http.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(raw) {
            return min(30, max(1, seconds))
        }
        return min(8, 1 << attempt)
    }

    private func makeWork(_ study: Study) -> Work {
        let module = study.protocolSection
        let identification = module.identificationModule
        let status = module.statusModule
        let design = module.designModule
        let description = module.descriptionModule
        let conditions = module.conditionsModule?.conditions ?? []
        let interventions = module.armsInterventionsModule?.interventions?.compactMap(\.name) ?? []
        let outcomes = module.outcomesModule?.primaryOutcomes?.compactMap(\.measure) ?? []
        let abstract = [
            description?.briefSummary,
            conditions.isEmpty ? nil : "Conditions: " + conditions.joined(separator: "; "),
            interventions.isEmpty ? nil : "Interventions: " + interventions.joined(separator: "; "),
            outcomes.isEmpty ? nil : "Primary outcomes: " + outcomes.joined(separator: "; "),
            design?.enrollmentInfo?.count.map { "Enrollment: \($0)" }
        ].compactMap { $0 }.joined(separator: "\n\n")
        let startDate = status?.startDateStruct?.date
        let year = startDate.flatMap { Int($0.prefix(4)) }
        let landing = "https://clinicaltrials.gov/study/\(identification.nctId)"
        let source = Source(displayName: "ClinicalTrials.gov")
        let location = Location(
            isOpenAccess: true,
            landingPageURL: landing,
            pdfURL: nil,
            source: source,
            license: nil,
            version: nil
        )
        let sponsor = module.sponsorCollaboratorsModule?.leadSponsor?.name
        let authors = sponsor.map { [Authorship(author: Author(id: nil, displayName: $0))] } ?? []
        return Work(
            id: landing,
            doi: nil,
            title: identification.officialTitle ?? identification.briefTitle,
            publicationDate: startDate,
            publicationYear: year,
            citedByCount: 0,
            authorships: authors,
            abstractInvertedIndex: nil,
            primaryLocation: location,
            bestOpenAccessLocation: location,
            openAccess: OpenAccess(isOpenAccess: true, status: "registry", openAccessURL: landing),
            contentURLs: nil,
            hasFullText: false,
            ids: nil,
            locations: [location],
            isRetracted: nil,
            type: "clinical-trial-registry",
            publicationTypes: ["Clinical Trial Registry", design?.studyType].compactMap { $0 },
            language: "en",
            abstractPlain: abstract.isEmpty ? nil : abstract
        )
    }
}

private extension ClinicalTrialsClient {
    struct Response: Decodable { let studies: [Study] }
    struct Study: Decodable { let protocolSection: ProtocolSection }
    struct ProtocolSection: Decodable {
        let identificationModule: IdentificationModule
        let statusModule: StatusModule?
        let sponsorCollaboratorsModule: SponsorModule?
        let descriptionModule: DescriptionModule?
        let conditionsModule: ConditionsModule?
        let designModule: DesignModule?
        let armsInterventionsModule: ArmsInterventionsModule?
        let outcomesModule: OutcomesModule?
    }
    struct IdentificationModule: Decodable {
        let nctId: String
        let briefTitle: String
        let officialTitle: String?
    }
    struct StatusModule: Decodable {
        let overallStatus: String?
        let startDateStruct: DateStruct?
        let primaryCompletionDateStruct: DateStruct?
    }
    struct DateStruct: Decodable { let date: String? }
    struct SponsorModule: Decodable { let leadSponsor: Sponsor? }
    struct Sponsor: Decodable { let name: String? }
    struct DescriptionModule: Decodable { let briefSummary: String? }
    struct ConditionsModule: Decodable { let conditions: [String]? }
    struct DesignModule: Decodable {
        let studyType: String?
        let phases: [String]?
        let enrollmentInfo: EnrollmentInfo?
    }
    struct EnrollmentInfo: Decodable { let count: Int? }
    struct ArmsInterventionsModule: Decodable { let interventions: [Intervention]? }
    struct Intervention: Decodable { let name: String? }
    struct OutcomesModule: Decodable { let primaryOutcomes: [Outcome]? }
    struct Outcome: Decodable { let measure: String? }
}
