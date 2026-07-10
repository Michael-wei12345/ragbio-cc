import Foundation

struct CredentialValidationResult {
    let isValid: Bool
    let message: String
}

enum CredentialValidator {
    static func openAlex(apiKey: String) async -> CredentialValidationResult {
        let clean = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .init(isValid: false, message: "请填写 API Key") }
        // Validate against one stable work instead of the slower full-text search endpoint.
        var components = URLComponents(
            string: "https://api.openalex.org/works/W2741809807"
        )
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: clean)
        ]
        return await test(url: components?.url, successMessage: "OpenAlex API Key 可用")
    }

    static func semanticScholar(apiKey: String) async -> CredentialValidationResult {
        let clean = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return .init(isValid: false, message: "请填写 API Key") }
        let url = URL(
            string: "https://api.semanticscholar.org/graph/v1/paper/"
                + "DOI:10.1038/nature12373?fields=paperId"
        )
        return await test(
            url: url,
            headers: ["x-api-key": clean],
            successMessage: "Semantic Scholar API Key 可用"
        )
    }

    static func unpaywall(email: String) async -> CredentialValidationResult {
        let clean = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.contains("@"), clean.contains(".") else {
            return .init(isValid: false, message: "请填写有效联系邮箱")
        }
        var components = URLComponents(
            string: "https://api.unpaywall.org/v2/10.1038/nature12373"
        )
        components?.queryItems = [URLQueryItem(name: "email", value: clean)]
        return await test(url: components?.url, successMessage: "Unpaywall 联系邮箱可用")
    }

    static func europePMC() async -> CredentialValidationResult {
        var components = URLComponents(
            string: "https://www.ebi.ac.uk/europepmc/webservices/rest/search"
        )
        components?.queryItems = [
            URLQueryItem(name: "query", value: "malaria"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "pageSize", value: "1")
        ]
        return await test(url: components?.url, successMessage: "Europe PMC 公共接口可用")
    }

    static func grobid(endpoint: String) async -> CredentialValidationResult {
        let clean = endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else {
            return .init(isValid: false, message: "请填写 GROBID 服务地址")
        }
        return await test(
            url: URL(string: "\(clean)/api/isalive"),
            successMessage: "GROBID 服务已就绪",
            validateBody: { data in
                String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "true"
            }
        )
    }

    private static func test(
        url: URL?,
        headers: [String: String] = [:],
        successMessage: String,
        validateBody: ((Data) -> Bool)? = nil
    ) async -> CredentialValidationResult {
        guard let url else { return .init(isValid: false, message: "请求地址无效") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("RagBio/0.3 credential validator", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .init(isValid: false, message: "无法识别服务器响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                return .init(
                    isValid: false,
                    message: "验证失败（HTTP \(http.statusCode)）"
                )
            }
            if let validateBody, !validateBody(data) {
                return .init(isValid: false, message: "服务有响应，但尚未准备完成")
            }
            return .init(isValid: true, message: successMessage)
        } catch {
            return .init(isValid: false, message: error.localizedDescription)
        }
    }
}
