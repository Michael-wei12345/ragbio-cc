import Foundation

struct AIQueryPlanner {
    var session: URLSession = .shared

    func plan(
        description: String,
        configuration: AIProviderConfiguration,
        currentSort: SearchSort,
        currentFromYear: Int?,
        currentOpenAccessOnly: Bool
    ) async throws -> AISearchPlan {
        guard configuration.isConfigured else {
            throw AIPlannerError.notConfigured(configuration.provider)
        }

        let acronymHint = acronymHints(for: description)
        let prompt = """
        You convert a user's research request into a search plan for the OpenAlex academic \
        works database. Do not invent papers, authors, DOIs, or results. Return only one JSON \
        object with these keys:
        - search_query: concise English scholarly keywords suitable for full-text search
        - pubmed_query: a PubMed query string. Group synonyms with OR inside parentheses and \
        join two or three distinct concepts with AND, using MeSH-style terms where helpful, e.g. \
        (gastrointestinal symptoms OR GI symptoms) AND (autism OR autism spectrum disorder) AND (child OR children OR infant). \
        Keep it to two or three concept groups so PubMed is not over-constrained and returns results.
        - from_year: integer or null
        - open_access_only: boolean
        - sort: one of relevance, newest, cited
        - explanation: one short Chinese sentence explaining the interpretation

        Preserve named genes, proteins, diseases, organisms, methods, and populations. The \
        search_query must be plain space-separated scholarly keywords for OpenAlex search; do \
        not use Boolean syntax such as AND, OR, NOT, parentheses, or field operators. Expand \
        common abbreviations only when useful. Do not reinterpret uppercase acronyms unless the \
        surrounding context clearly supports that expansion. For ambiguous acronyms, preserve the \
        acronym and add a likely scholarly expansion instead of replacing the acronym. Respect \
        explicit constraints in the request. If no constraint is stated, use the current UI values.

        Acronym hints: \(acronymHint)

        Current sort: \(currentSort.rawValue)
        Current from year: \(currentFromYear.map(String.init) ?? "null")
        Current open access only: \(currentOpenAccessOnly)
        User request: \(description)
        """

        let data: Data
        switch configuration.provider {
        case .deepSeek, .openAI:
            data = try await openAICompatible(
                prompt: prompt,
                configuration: configuration,
                maxTokens: 420,
                timeout: 10
            )
        case .anthropic:
            data = try await anthropic(
                prompt: prompt,
                configuration: configuration,
                maxTokens: 420,
                timeout: 10
            )
        case .gemini:
            data = try await gemini(
                prompt: prompt,
                configuration: configuration,
                maxTokens: 420,
                timeout: 10
            )
        }
        return try decodePlan(from: data)
    }

    private func acronymHints(for description: String) -> String {
        var hints: [String] = []
        if description.range(of: #"\bNDC\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            hints.append(
                "In clinical, medication, pharmacy, claims, adverse-event, EHR, or drug-code contexts, NDC usually means National Drug Code(s). Keep both \"NDC\" and \"National Drug Code(s)\" in search_query unless the user clearly means another expansion."
            )
        }
        return hints.isEmpty ? "none" : hints.joined(separator: " ")
    }

    func validate(
        configuration: AIProviderConfiguration
    ) async -> CredentialValidationResult {
        do {
            _ = try await plan(
                description: "Find recent CRISPR off-target detection papers",
                configuration: configuration,
                currentSort: .relevance,
                currentFromYear: nil,
                currentOpenAccessOnly: false
            )
            return .init(
                isValid: true,
                message: "\(configuration.provider.title) 与模型 \(configuration.model) 可用"
            )
        } catch {
            return .init(isValid: false, message: error.localizedDescription)
        }
    }

    func rankEvidenceBatch(
        description: String,
        inputs: [AIEvidenceRankingInput],
        configuration: AIProviderConfiguration
    ) async throws -> [AIRankedCandidate] {
        guard configuration.isConfigured else {
            throw AIPlannerError.notConfigured(configuration.provider)
        }
        guard !inputs.isEmpty else { return [] }

        let candidateText = inputs.enumerated().map { index, input in
            let abstract = String((input.abstract ?? "No abstract available").prefix(600))
            let passages = input.passages.prefix(2).map { hit in
                "\(hit.paragraph.locator): \(String(hit.paragraph.text.prefix(700)))"
            }.joined(separator: "\n")
            return """
            [\(index)]
            Title: \(input.work.title)
            Year: \(input.work.publicationYear.map(String.init) ?? "unknown")
            Venue: \(input.work.venue)
            Abstract: \(abstract)
            Full-text evidence: \(passages.isEmpty ? "Not available" : passages)
            """
        }.joined(separator: "\n\n")

        let prompt = """
        Rank these papers for the user's ORIGINAL research request using only the supplied abstract \
        and full-text evidence. Judge whether each paper actually answers the request, not keyword \
        overlap. Return exactly one item for every supplied index as JSON:
        {"rankings":[{"index":0,"score":0,"relevant":false,"reason":"中文证据总结"}]}

        score must be an integer from 0 to 100. relevant is true only when the supplied evidence is \
        genuinely useful. reason must be one short Simplified Chinese sentence based only on the \
        supplied evidence. Do not invent facts or use outside knowledge.

        Original request: \(description)

        Candidates:
        \(candidateText)
        """

        let data = try await generateJSON(
            prompt: prompt,
            configuration: configuration,
            maxTokens: max(1_200, inputs.count * 80),
            timeout: 25
        )
        let decoded = try decodeJSON(AIRankingResponse.self, from: data)
        let valid = decoded.rankings.filter { inputs.indices.contains($0.index) }
        guard valid.count == inputs.count,
              Set(valid.map(\.index)).count == inputs.count else {
            throw AIPlannerError.invalidRanking
        }
        return valid
    }

    func rankAbstractBatch(
        description: String,
        inputs: [AIAbstractRankingInput],
        configuration: AIProviderConfiguration
    ) async throws -> [AIRankedCandidate] {
        guard configuration.isConfigured else {
            throw AIPlannerError.notConfigured(configuration.provider)
        }
        guard !inputs.isEmpty else { return [] }

        let candidateText = inputs.enumerated().map { index, input in
            let abstract = String((input.abstract ?? "No abstract available").prefix(700))
            return """
            [\(index)]
            Title: \(input.work.title)
            Year: \(input.work.publicationYear.map(String.init) ?? "unknown")
            Venue: \(input.work.venue)
            Abstract: \(abstract)
            """
        }.joined(separator: "\n\n")

        let prompt = """
        Rank these papers for the user's ORIGINAL research request using only the supplied title, \
        venue, year, and abstract. Judge whether each paper actually answers the request, not \
        keyword overlap. Return exactly one item for every supplied index as JSON:
        {"rankings":[{"index":0,"score":0,"relevant":false,"reason":"中文摘要依据"}]}

        score must be an integer from 0 to 100. relevant is true only when the supplied abstract \
        is genuinely useful. reason must be one short Simplified Chinese sentence based only on \
        the supplied metadata and abstract. Do not invent facts or use outside knowledge.

        Original request: \(description)

        Candidates:
        \(candidateText)
        """

        let data = try await generateJSON(
            prompt: prompt,
            configuration: configuration,
            maxTokens: max(1_200, inputs.count * 80),
            timeout: 25
        )
        let decoded = try decodeJSON(AIRankingResponse.self, from: data)
        let valid = decoded.rankings.filter { inputs.indices.contains($0.index) }
        guard valid.count == inputs.count,
              Set(valid.map(\.index)).count == inputs.count else {
            throw AIPlannerError.invalidRanking
        }
        return valid
    }

    func translateBatch(
        _ items: [AITranslationInput],
        configuration: AIProviderConfiguration
    ) async throws -> [AITranslationOutput] {
        guard configuration.isConfigured else {
            throw AIPlannerError.notConfigured(configuration.provider)
        }
        guard !items.isEmpty else { return [] }

        let payload = try JSONSerialization.data(
            withJSONObject: items.map { ["id": $0.id, "text": $0.text] }
        )
        guard let payloadText = String(data: payload, encoding: .utf8) else {
            throw AIPlannerError.invalidResponse
        }
        let prompt = """
        Translate every input text into Simplified Chinese. Preserve scientific terminology, \
        numbers, citations, section labels, URLs, and paragraph meaning. Do not summarize, omit, \
        explain, or add facts. Return exactly one translation for every input id.

        Return only:
        {"translations":[{"id":"item-0","translation":"中文译文"}]}

        Inputs:
        \(payloadText)
        """
        let characterCount = items.reduce(0) { $0 + $1.text.count }
        let data = try await generateJSON(
            prompt: prompt,
            configuration: configuration,
            maxTokens: min(8_000, max(1_200, characterCount * 2)),
            timeout: 45
        )
        let decoded = try decodeJSON(AITranslationResponse.self, from: data)
        let validIDs = Set(items.map(\.id))
        let outputs = decoded.translations.filter {
            validIDs.contains($0.id)
                && !$0.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !outputs.isEmpty else { throw AIPlannerError.invalidTranslation }
        return outputs
    }

    func summarizeFullTextBatch(
        _ items: [AIFullTextSummaryInput],
        configuration: AIProviderConfiguration
    ) async throws -> [AIFullTextSummaryOutput] {
        guard configuration.isConfigured else {
            throw AIPlannerError.notConfigured(configuration.provider)
        }
        guard !items.isEmpty else { return [] }

        let candidateText = items.enumerated().map { index, item in
            """
            [\(index)]
            Title: \(item.work.title)
            Year: \(item.work.publicationYear.map(String.init) ?? "unknown")
            Venue: \(item.work.venue)
            Source: \(item.document.source.title)
            Full text excerpts:
            \(fullTextSummaryContext(from: item.document))
            """
        }.joined(separator: "\n\n")

        let prompt = """
        Summarize each full-text academic paper for use in a literature review. Use ONLY the \
        supplied full-text excerpts. Do not use model memory and do not invent findings. If a \
        field is not explicit in the excerpts, write "The supplied full-text excerpts do not \
        clearly report this."

        Return only this JSON object:
        {"summaries":[{"index":0,"topic":"English","methods":"English","results":"English","outlook":"English","metrics":["Labeled English metric"]}]}

        Requirements:
        - Return exactly one summary for every supplied index.
        - Write in clear academic English.
        - Each field must be a complete, self-contained sentence that a reader can understand
          without seeing the abstract.
        - topic: what the paper studies, in 1 concise sentence.
        - methods: study design, data source, sample, measures, or analysis method.
        - results: main findings only, with context for every statistic.
        - outlook: limitations, implications, future work, or conclusion.
        - metrics: exact sample sizes, percentages, effect sizes, p-values, code counts, \
          database counts, dates, or other quantitative indicators explicitly present; max 6.
        - Every metric must include a label and context, for example "Sample size: 152,904
          veterans" or "OIC prevalence: 12.6%". Never return bare values such as "152,904",
          "12.6%", or "98%".
        - Preserve drug codes, database names, instruments, and statistical values exactly.
        - Do not add generic relevance phrases.

        Papers:
        \(candidateText)
        """

        let data = try await generateJSON(
            prompt: prompt,
            configuration: configuration,
            maxTokens: max(1_500, items.count * 700),
            timeout: 35
        )
        let decoded = try decodeJSON(AIFullTextSummaryResponse.self, from: data)
        let valid = decoded.summaries.filter { items.indices.contains($0.index) }
        guard !valid.isEmpty else { throw AIPlannerError.invalidResponse }
        return valid
    }

    private struct ArticleNoteResponse: Decodable { let note: String }

    /// Produces a systematic-review-oriented extraction note for a single full-text paper,
    /// strictly grounded in the supplied full-text excerpts.
    func articleExtractionNote(
        work: Work,
        document: FullTextDocument,
        configuration: AIProviderConfiguration
    ) async throws -> String {
        guard configuration.isConfigured else {
            throw AIPlannerError.notConfigured(configuration.provider)
        }
        let context = fullTextSummaryContext(from: document)
        let prompt = """
        You are a biomedical systematic-review assistant. Do NOT write a generic article summary. \
        Produce a systematic-review-oriented extraction note, strictly grounded ONLY in the supplied \
        full-text excerpts. Do not speculate and do not use outside knowledge. For each key \
        conclusion, cite the source section/paragraph — each excerpt is prefixed with a locator such \
        as "[Methods · Paragraph 9]". If something is not reported in the excerpts, write "Not reported". \
        Write in English. Do not use curly braces anywhere inside the note text.

        Begin the note with ONE prominent line, exactly in this form:
        Screening verdict: <Include as primary evidence | Include as background | Maybe | Exclude> — <one short reason>

        Adapt the depth to the study type. If the paper is a narrative review, systematic review, or \
        meta-analysis, or otherwise reports no primary dataset, keep sections 4–7 short: one brief line \
        each noting that primary methods/data are not applicable, instead of repeating "Not reported" \
        many times. Do the full detailed extraction only for primary studies. Length: about 250–450 \
        words for primary studies, and shorter (about 150–250 words) for reviews.

        Use exactly this structure and keep the headers:

        Screening verdict: ...
        1. How I can use this paper in my review:
        2. One-line takeaway:
        3. Study type and role in my review:
        (Say whether it is a primary study, RCT, cohort, case-control, cross-sectional, systematic \
        review, meta-analysis, narrative review, or other; and whether it is suitable as primary \
        evidence for a systematic review, and why.)
        4. PICO / PECO:
        - Population:
        - Exposure / Condition:
        - Comparator:
        - Outcomes:
        5. Methods that matter:
        - Databases / search period:
        - Inclusion criteria:
        - Sample type:
        - Bio methods:
        - Statistical methods:
        6. Main biological findings:
        (Bullet points. For each, give the biomarker / taxa / gene / pathway, the direction \
        increased/decreased, the disease or population, and whether it was statistically significant. \
        Do not write vague statements like "gut microbiota changed".)
        7. Limitations and confounders:
        (e.g. sample size, heterogeneity, diet, medication, age, sex, GI symptoms, sequencing method, \
        batch effects.)
        Return ONLY this JSON object: {"note":"<the full note as a single JSON string, using \\n for line breaks>"}

        Paper title: \(work.title)
        Full-text excerpts:
        \(context)
        """
        let data = try await generateJSON(
            prompt: prompt,
            configuration: configuration,
            maxTokens: 1_400,
            timeout: 45
        )
        let decoded = try decodeJSON(ArticleNoteResponse.self, from: data)
        let note = decoded.note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { throw AIPlannerError.invalidResponse }
        return note
    }

    func fieldScanDraft(
        query: String,
        normalizedQuery: String?,
        rows: [EvidenceTableRow],
        snapshot: FieldScanInputSnapshot,
        configuration: AIProviderConfiguration
    ) async throws -> FieldScanDraftResponse {
        guard configuration.isConfigured else {
            throw AIPlannerError.notConfigured(configuration.provider)
        }
        guard !rows.isEmpty else { throw AIPlannerError.invalidResponse }

        let rowPayload = rows.map { row in
            [
                "work_id": row.workID,
                "title": row.title,
                "year": row.year.map(String.init) ?? "unknown",
                "venue": row.venue ?? "unknown",
                "decision": row.scanDecision.rawValue,
                "access_status": row.accessStatus.rawValue,
                "ai_score": row.aiScore.map { String(format: "%.0f", $0) } ?? "",
                "ai_reason": row.aiReason ?? "",
                "topic": row.summaryTopic ?? "",
                "methods": row.summaryMethods ?? "",
                "results": row.summaryResults ?? "",
                "key_metrics": row.summaryKeyMetrics ?? "",
                "outlook": row.summaryOutlook ?? "",
                "abstract": String((row.abstractText ?? "").prefix(900)),
                "source_refs": row.sourceRefs.map {
                    "\($0.field): \($0.locator) - \(String($0.quotePreview.prefix(220)))"
                }.joined(separator: "\n")
            ]
        }
        let payload = try JSONSerialization.data(withJSONObject: rowPayload)
        let payloadText = String(data: payload, encoding: .utf8) ?? "[]"

        let warnings = [
            snapshot.rowCount < 5
                ? "The input has fewer than 5 papers; explicitly include this as a limitation."
                : nil,
            snapshot.fullTextSupportedCount == 0
                ? "The input has no full-text-supported papers; explicitly include this as a limitation."
                : nil
        ]
        .compactMap { $0 }
        .joined(separator: " ")

        let prompt = """
        You are generating a SHORT, high-signal research landscape scan for a busy researcher — \
        get straight to the point, no filler, no popular-science tone. Use only the provided \
        Evidence Table rows. Do not use outside knowledge. Do not cite papers not present in the \
        input. Every claim must include supporting_work_ids. If a claim cannot be supported by at \
        least one supplied work_id, omit it. Use cautious language such as "suggests", "reports", \
        "is associated with", or "is consistent with". Do not claim proof or causality unless the \
        provided evidence explicitly supports it. Distinguish abstract-only evidence from \
        full-text-supported evidence. \(warnings)

        Be concise. Hard limits: field_overview = at most 3 sentences that lead with the bottom \
        line. key_findings = at most 5 items, each ONE tight sentence. conflicting_evidence = at \
        most 3. research_gaps = at most 3. must_read_papers = at most 6, most important first. \
        main_themes, common_methods, future_directions, and limitations may be brief or empty. \
        Prefer fewer, sharper points over long lists.

        Return JSON only with this shape:
        {
          "field_overview": "string",
          "main_themes": [{"name":"string","summary":"string","supporting_work_ids":["work-id"]}],
          "key_findings": [{"text":"string","supporting_work_ids":["work-id"],"caution":"string or null"}],
          "conflicting_evidence": [{"text":"string","supporting_work_ids":["work-id"],"caution":"string or null"}],
          "common_methods": [{"text":"string","supporting_work_ids":["work-id"],"caution":"string or null"}],
          "research_gaps": [{"text":"string","supporting_work_ids":["work-id"],"caution":"string or null"}],
          "future_directions": [{"text":"string","supporting_work_ids":["work-id"],"caution":"string or null"}],
          "must_read_papers": [{"work_id":"work-id","title":"string","reason":"string","category":"foundational|recent|methodologicallyUseful|fullTextAvailable|highlyRelevant"}],
          "limitations": ["string"]
        }

        Query: \(query)
        Normalized query: \(normalizedQuery ?? "none")
        Snapshot: rows=\(snapshot.rowCount), full_text=\(snapshot.fullTextSupportedCount), abstract_only=\(snapshot.abstractOnlyCount), unreviewed=\(snapshot.unreviewedCount), generated_from_decisions=\(snapshot.generatedFromDecisions)

        Evidence Table rows:
        \(payloadText)
        """

        let data = try await generateJSON(
            prompt: prompt,
            configuration: configuration,
            maxTokens: 3_000,
            timeout: 45
        )
        return try decodeJSON(FieldScanDraftResponse.self, from: data)
    }

    private func fullTextSummaryContext(from document: FullTextDocument) -> String {
        let preferredTerms = [
            "abstract", "summary", "introduction", "background",
            "method", "methods", "materials", "participants", "data",
            "result", "results", "finding", "findings",
            "discussion", "conclusion", "limitations", "future"
        ]
        let preferred = document.paragraphs.filter { paragraph in
            let section = paragraph.section.lowercased()
            return preferredTerms.contains { section.contains($0) }
        }
        let source = preferred.isEmpty ? Array(document.paragraphs.prefix(16)) : preferred
        var total = 0
        var lines: [String] = []
        for paragraph in source {
            let text = paragraph.text
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 40 else { continue }
            let clipped = String(text.prefix(900))
            lines.append("[\(paragraph.locator)] \(clipped)")
            total += clipped.count
            if total >= 7_000 { break }
        }
        return lines.joined(separator: "\n")
    }

    private func openAICompatible(
        prompt: String,
        configuration: AIProviderConfiguration,
        maxTokens: Int? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        let url = try endpoint(configuration.baseURL, path: "v1/chat/completions")
        var body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": "Return valid JSON only."],
                ["role": "user", "content": prompt]
            ],
            "response_format": ["type": "json_object"]
        ]
        if configuration.provider == .deepSeek {
            // DeepSeek V4 enables thinking by default. Search planning, ranking,
            // and translation are structured low-latency tasks, so hidden
            // reasoning only adds substantial delay without improving fidelity.
            body["thinking"] = ["type": "disabled"]
        }
        if let maxTokens {
            if configuration.provider == .openAI {
                body["max_completion_tokens"] = maxTokens
            } else {
                body["max_tokens"] = maxTokens
            }
        }
        let response = try await request(
            url: url,
            headers: ["Authorization": "Bearer \(configuration.apiKey)"],
            body: body,
            timeout: timeout
        )
        guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AIPlannerError.invalidResponse
        }
        return Data(content.utf8)
    }

    private func anthropic(
        prompt: String,
        configuration: AIProviderConfiguration,
        maxTokens: Int = 600,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        let url = try endpoint(configuration.baseURL, path: "v1/messages")
        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": maxTokens,
            "system": "Return valid JSON only.",
            "messages": [["role": "user", "content": prompt]]
        ]
        let response = try await request(
            url: url,
            headers: [
                "x-api-key": configuration.apiKey,
                "anthropic-version": "2023-06-01"
            ],
            body: body,
            timeout: timeout
        )
        guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let content = root["content"] as? [[String: Any]],
              let text = content.first(where: { $0["type"] as? String == "text" })?["text"]
                as? String else {
            throw AIPlannerError.invalidResponse
        }
        return Data(text.utf8)
    }

    private func gemini(
        prompt: String,
        configuration: AIProviderConfiguration,
        maxTokens: Int? = nil,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        let encodedModel = configuration.model.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? configuration.model
        var components = URLComponents(
            url: try endpoint(
                configuration.baseURL,
                path: "v1beta/models/\(encodedModel):generateContent"
            ),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "key", value: configuration.apiKey)]
        guard let url = components?.url else { throw AIPlannerError.invalidEndpoint }
        var generationConfig: [String: Any] = [
            "temperature": 0,
            "responseMimeType": "application/json"
        ]
        if let maxTokens {
            generationConfig["maxOutputTokens"] = maxTokens
        }
        let body: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            "generationConfig": generationConfig
        ]
        let response = try await request(url: url, headers: [:], body: body, timeout: timeout)
        guard let root = try JSONSerialization.jsonObject(with: response) as? [String: Any],
              let candidates = root["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]],
              let text = parts.first?["text"] as? String else {
            throw AIPlannerError.invalidResponse
        }
        return Data(text.utf8)
    }

    private func generateJSON(
        prompt: String,
        configuration: AIProviderConfiguration,
        maxTokens: Int,
        timeout: TimeInterval = 30
    ) async throws -> Data {
        switch configuration.provider {
        case .deepSeek, .openAI:
            return try await openAICompatible(
                prompt: prompt,
                configuration: configuration,
                maxTokens: maxTokens,
                timeout: timeout
            )
        case .anthropic:
            return try await anthropic(
                prompt: prompt,
                configuration: configuration,
                maxTokens: maxTokens,
                timeout: timeout
            )
        case .gemini:
            return try await gemini(
                prompt: prompt,
                configuration: configuration,
                maxTokens: maxTokens,
                timeout: timeout
            )
        }
    }

    private func request(
        url: URL,
        headers: [String: String],
        body: [String: Any],
        timeout: TimeInterval = 30
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("RagBio/0.4 AI search planner", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIPlannerError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let raw = String(data: data, encoding: .utf8) ?? "未知错误"
            throw AIPlannerError.api(
                status: http.statusCode,
                message: String(raw.prefix(500))
            )
        }
        return data
    }

    private func endpoint(_ baseURL: String, path: String) throws -> URL {
        let clean = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: "\(clean)/\(path)") else {
            throw AIPlannerError.invalidEndpoint
        }
        return url
    }

    private func decodePlan(from data: Data) throws -> AISearchPlan {
        let plan = try decodeJSON(AISearchPlan.self, from: data)
        let searchQuery = OpenAlexQueryNormalizer.normalize(plan.searchQuery)
        guard !searchQuery.isEmpty else {
            throw AIPlannerError.invalidPlan
        }
        return AISearchPlan(
            searchQuery: searchQuery,
            fromYear: plan.fromYear,
            openAccessOnly: plan.openAccessOnly,
            sort: plan.sort,
            explanation: plan.explanation,
            pubMedQuery: plan.pubMedQuery
        )
    }

    private func decodeJSON<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        guard let raw = String(data: data, encoding: .utf8) else {
            throw AIPlannerError.malformedJSON
        }
        let text = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let jsonText: String
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}"),
           start <= end {
            jsonText = String(text[start...end])
        } else {
            throw AIPlannerError.malformedJSON
        }

        do {
            return try JSONDecoder().decode(type, from: Data(jsonText.utf8))
        } catch is DecodingError {
            throw AIPlannerError.malformedJSON
        }
    }
}
