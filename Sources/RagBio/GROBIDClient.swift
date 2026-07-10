import Foundation

enum GROBIDClient {
    static func parse(
        pdfData: Data,
        workID: String,
        title: String,
        sourceURL: String?,
        endpoint: String
    ) async throws -> FullTextDocument {
        guard let url = processURL(from: endpoint) else {
            throw SearchError.invalidURL
        }

        let boundary = "RagBio-\(UUID().uuidString)"
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8(
            "Content-Disposition: form-data; name=\"input\"; filename=\"paper.pdf\"\r\n"
        )
        body.appendUTF8("Content-Type: application/pdf\r\n\r\n")
        body.append(pdfData)
        body.appendUTF8("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/xml,text/xml", forHTTPHeaderField: "Accept")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw SearchError.invalidResponse
        }
        return try StructuredXMLParser().parse(
            data: data,
            workID: workID,
            title: title,
            source: .localGROBID,
            sourceURL: sourceURL
        )
    }

    private static func processURL(from endpoint: String) -> URL? {
        let clean = endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !clean.isEmpty else { return nil }
        if clean.hasSuffix("api/processFulltextDocument") {
            return URL(string: clean)
        }
        return URL(string: "\(clean)/api/processFulltextDocument")
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        if let data = value.data(using: .utf8) {
            append(data)
        }
    }
}
