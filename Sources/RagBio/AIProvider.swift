import Foundation

extension Notification.Name {
    static let ragBioAIConfigurationCleared = Notification.Name(
        "RagBioAIConfigurationCleared"
    )
}

enum AIProvider: String, CaseIterable, Identifiable, Codable {
    case deepSeek
    case openAI
    case anthropic
    case gemini

    var id: Self { self }

    var title: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .openAI: return "OpenAI"
        case .anthropic: return "Anthropic Claude"
        case .gemini: return "Google Gemini"
        }
    }

    var defaultModel: String {
        switch self {
        case .deepSeek: return "deepseek-v4-flash"
        case .openAI: return "gpt-5.4-mini"
        case .anthropic: return "claude-sonnet-4-6"
        case .gemini: return "gemini-3.5-flash"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .deepSeek: return "https://api.deepseek.com"
        case .openAI: return "https://api.openai.com"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        }
    }

    var documentationURL: URL {
        switch self {
        case .deepSeek:
            return URL(string: "https://api-docs.deepseek.com/")!
        case .openAI:
            return URL(string: "https://developers.openai.com/api/docs/models")!
        case .anthropic:
            return URL(string: "https://docs.anthropic.com/en/docs/about-claude/models")!
        case .gemini:
            return URL(string: "https://ai.google.dev/gemini-api/docs/models")!
        }
    }

    var recommendedModels: [String] {
        switch self {
        case .deepSeek:
            return ["deepseek-v4-flash", "deepseek-v4-pro"]
        case .openAI:
            return [
                "gpt-5.6",
                "gpt-5.4-nano",
                "gpt-5.4-mini",
                "gpt-5.4",
                "gpt-5.5"
            ]
        case .anthropic:
            return ["claude-sonnet-4-6", "claude-haiku-4-5", "claude-opus-4-8"]
        case .gemini:
            return [
                "gemini-3.1-flash-lite",
                "gemini-3.5-flash",
                "gemini-3.1-pro-preview",
                "gemini-2.5-pro"
            ]
        }
    }

    var credentialKey: CredentialKey {
        switch self {
        case .deepSeek: return .deepSeekAPIKey
        case .openAI: return .openAIAPIKey
        case .anthropic: return .anthropicAPIKey
        case .gemini: return .geminiAPIKey
        }
    }
}

struct AIProviderConfiguration {
    let provider: AIProvider
    let apiKey: String
    let model: String
    let baseURL: String

    static func load(_ provider: AIProvider) -> Self {
        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: SettingsKeys.aiModel(provider))
            ?? provider.defaultModel
        let baseURL = defaults.string(forKey: SettingsKeys.aiBaseURL(provider))
            ?? provider.defaultBaseURL
        return .init(
            provider: provider,
            apiKey: CredentialStore.string(for: provider.credentialKey),
            model: model,
            baseURL: baseURL
        )
    }

    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct AISearchPlan: Codable, Equatable {
    let searchQuery: String
    let fromYear: Int?
    let openAccessOnly: Bool
    let sort: SearchSort
    let explanation: String
    let pubMedQuery: String?

    init(
        searchQuery: String,
        fromYear: Int?,
        openAccessOnly: Bool,
        sort: SearchSort,
        explanation: String,
        pubMedQuery: String? = nil
    ) {
        self.searchQuery = searchQuery
        self.fromYear = fromYear
        self.openAccessOnly = openAccessOnly
        self.sort = sort
        self.explanation = explanation
        self.pubMedQuery = pubMedQuery
    }

    enum CodingKeys: String, CodingKey {
        case searchQuery = "search_query"
        case fromYear = "from_year"
        case openAccessOnly = "open_access_only"
        case sort
        case explanation
        case pubMedQuery = "pubmed_query"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        searchQuery = try values.decode(String.self, forKey: .searchQuery)
        fromYear = try values.decodeFlexibleIntIfPresent(forKey: .fromYear)
        openAccessOnly = try values.decodeFlexibleBoolIfPresent(forKey: .openAccessOnly) ?? false
        let rawSort = try values.decodeIfPresent(String.self, forKey: .sort) ?? "relevance"
        sort = SearchSort(rawValue: rawSort) ?? .relevance
        explanation = try values.decodeIfPresent(String.self, forKey: .explanation) ?? ""
        pubMedQuery = try values.decodeIfPresent(String.self, forKey: .pubMedQuery)
    }
}

struct AIRankedCandidate: Decodable, Equatable {
    let index: Int
    let score: Int
    let relevant: Bool
    let reason: String

    enum CodingKeys: String, CodingKey {
        case index, score, relevant, reason
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let index = try values.decodeFlexibleIntIfPresent(forKey: .index),
              let score = try values.decodeFlexibleIntIfPresent(forKey: .score) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Ranking index and score must be numbers"
                )
            )
        }
        self.index = index
        self.score = score
        relevant = try values.decodeFlexibleBoolIfPresent(forKey: .relevant) ?? false
        reason = try values.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

struct AIRankingResponse: Decodable {
    let rankings: [AIRankedCandidate]
}

struct AITranslationInput {
    let id: String
    let text: String
}

struct AITranslationOutput: Decodable {
    let id: String
    let translation: String
}

struct AITranslationResponse: Decodable {
    let translations: [AITranslationOutput]
}

struct AIFullTextSummaryInput {
    let work: Work
    let document: FullTextDocument
}

struct AIFullTextSummaryOutput: Decodable {
    let index: Int
    let topic: String
    let methods: String
    let results: String
    let outlook: String
    let metrics: [String]

    enum CodingKeys: String, CodingKey {
        case index, topic, methods, results, outlook, metrics
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard let index = try values.decodeFlexibleIntIfPresent(forKey: .index) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Full-text summary index must be a number"
                )
            )
        }
        self.index = index
        topic = try values.decodeIfPresent(String.self, forKey: .topic) ?? ""
        methods = try values.decodeIfPresent(String.self, forKey: .methods) ?? ""
        results = try values.decodeIfPresent(String.self, forKey: .results) ?? ""
        outlook = try values.decodeIfPresent(String.self, forKey: .outlook) ?? ""
        metrics = try values.decodeIfPresent([String].self, forKey: .metrics) ?? []
    }

    var summary: LiteratureReviewSummary {
        LiteratureReviewSummary(
            topic: topic,
            methods: methods,
            results: results,
            outlook: outlook,
            metrics: metrics
        )
    }
}

struct AIFullTextSummaryResponse: Decodable {
    let summaries: [AIFullTextSummaryOutput]
}

struct AIEvidenceRankingInput {
    let work: Work
    let abstract: String?
    let passages: [PassageHit]
    let source: FullTextSource?

    var hasFullTextEvidence: Bool {
        source?.isFullText == true && !passages.isEmpty
    }
}

enum AIRerankState: Equatable {
    case idle
    case fetchingCandidates
    case localReady(candidates: Int)
    case ranking(completed: Int, total: Int)
    case completed(candidates: Int, retained: Int)
    case failed(message: String, candidates: Int)
}

enum AISecondRerankState: Equatable {
    case idle
    case fetchingEvidence(completed: Int, total: Int)
    case rankingEvidence(completed: Int, total: Int)
    case refiningFullText(completed: Int, total: Int)
    case completed(fullText: Int, abstractOnly: Int, retained: Int)
    case failed(String)

    var isTerminal: Bool {
        switch self {
        case .completed, .failed:
            return true
        default:
            return false
        }
    }
}

enum AIPlannerError: LocalizedError {
    case notConfigured(AIProvider)
    case invalidEndpoint
    case invalidResponse
    case api(status: Int, message: String)
    case invalidPlan
    case invalidRanking
    case invalidTranslation
    case malformedJSON

    var errorDescription: String? {
        switch self {
        case let .notConfigured(provider):
            return "尚未配置 \(provider.title)。请在设置的“大模型与 AI 搜索”中填写 API Key 和模型。"
        case .invalidEndpoint:
            return "大模型接口地址无效。"
        case .invalidResponse:
            return "大模型返回了无法识别的响应。"
        case let .api(status, message):
            return "大模型请求失败（HTTP \(status)）：\(message)"
        case .invalidPlan:
            return "大模型没有生成有效的学术检索计划。"
        case .invalidRanking:
            return "大模型没有返回有效的论文相关性排序。"
        case .invalidTranslation:
            return "大模型没有返回有效的逐段翻译。"
        case .malformedJSON:
            return "大模型返回的 JSON 格式异常，请重试。"
        }
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
        if !contains(key) || (try? decodeNil(forKey: key)) == true {
            return nil
        }
        if let value = try? decode(Int.self, forKey: key) {
            return value
        }
        if let value = try? decode(Double.self, forKey: key) {
            return Int(value.rounded())
        }
        if let value = try? decode(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        throw DecodingError.typeMismatch(
            Int.self,
            .init(
                codingPath: codingPath + [key],
                debugDescription: "Expected an integer or numeric string"
            )
        )
    }

    func decodeFlexibleBoolIfPresent(forKey key: Key) throws -> Bool? {
        if !contains(key) || (try? decodeNil(forKey: key)) == true {
            return nil
        }
        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }
        if let value = try? decode(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? decode(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                break
            }
        }
        throw DecodingError.typeMismatch(
            Bool.self,
            .init(
                codingPath: codingPath + [key],
                debugDescription: "Expected a boolean or boolean string"
            )
        )
    }
}

enum AISearchPipelineError: LocalizedError {
    case searchPlanning(String)
    case openAlexKeyRequired
    case candidateFetch(String)

    var errorDescription: String? {
        switch self {
        case let .searchPlanning(message):
            return "AI 检索计划生成失败：\(message)"
        case .openAlexKeyRequired:
            return "AI 搜索需要 OpenAlex 免费 API Key。请在“设置 → 信息源与访问权限 → OpenAlex”中填写并测试，避免匿名搜索接口超时。"
        case let .candidateFetch(message):
            return "OpenAlex 候选论文获取失败：\(message)"
        }
    }
}
