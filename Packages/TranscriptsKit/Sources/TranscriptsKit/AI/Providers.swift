import Foundation

// MARK: - Anthropic

/// Claude through the Messages API.
public struct AnthropicProvider: LLMProvider {
    public let kind = ProviderKind.anthropic
    let apiKey: String
    let http: HTTPClient
    let baseURL: URL

    /// Used when the account's model list can't be read.
    public static let defaultModel = "claude-opus-5-5"

    public init(apiKey: String, session: URLSession = .shared, baseURL: URL = URL(string: "https://api.anthropic.com/v1/")!) {
        self.apiKey = apiKey
        self.http = HTTPClient(provider: .anthropic, session: session)
        self.baseURL = baseURL
    }

    /// Claude reads a million tokens; a very long meeting still fits in one request.
    public var contextCharacters: Int { 900_000 }

    private var headers: [String: String] {
        ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
    }

    public func models() async throws -> [LLMModel] {
        let request = try HTTPClient.jsonRequest(baseURL.appendingPathComponent("models").appending(queryItems: [URLQueryItem(name: "limit", value: "100")]), method: "GET", headers: headers, timeout: 30)
        let json = try await http.send(request)
        let models = (json["data"]?.array ?? []).compactMap { item -> LLMModel? in
            guard let id = item["id"]?.string else { return nil }
            return LLMModel(id: id, name: item["display_name"]?.string ?? id)
        }
        guard !models.isEmpty else { throw LLMError.noModels(.anthropic) }
        // The API lists newest first; put the recommended default on top.
        return models.sorted { lhs, rhs in
            if lhs.id == Self.defaultModel { return true }
            if rhs.id == Self.defaultModel { return false }
            return false
        }
    }

    public func complete(_ request: LLMRequest, model: String) async throws -> String {
        do {
            return try await send(request, model: model, structured: request.schema != nil)
        } catch LLMError.server(_, 400, let message) where request.schema != nil && Self.isUnsupportedFormat(message) {
            // Older models without structured outputs: ask for JSON in words instead.
            return try await send(request, model: model, structured: false)
        }
    }

    private func send(_ request: LLMRequest, model: String, structured: Bool) async throws -> String {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(request.maxOutputTokens)),
            "system": .string(request.system),
            "messages": [["role": "user", "content": .string(request.prompt)]],
        ]
        var outputConfig: [String: JSONValue] = [:]
        if Self.supportsEffort(model) { outputConfig["effort"] = "medium" }
        if structured, let schema = request.schema {
            outputConfig["format"] = ["type": "json_schema", "schema": .object(schema)]
        }
        if !outputConfig.isEmpty { body["output_config"] = .object(outputConfig) }
        var headers = headers
        if Self.supportsServerFallback(model) {
            // If a safety classifier declines, Anthropic re-runs the request on its recommended model.
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
            body["fallbacks"] = "default"
        }
        let urlRequest = try HTTPClient.jsonRequest(baseURL.appendingPathComponent("messages"), headers: headers, body: .object(body))
        let json = try await http.send(urlRequest)
        switch json["stop_reason"]?.string {
        case "refusal":
            throw LLMError.refused(json["stop_details"]?["category"]?.string ?? "")
        case "max_tokens":
            throw LLMError.truncated
        default:
            break
        }
        let text = (json["content"]?.array ?? [])
            .filter { $0["type"]?.string == "text" }
            .compactMap { $0["text"]?.string }
            .joined()
        guard !text.isEmpty else { throw LLMError.badResponse("Leere Antwort") }
        return text
    }

    /// The `effort` setting exists on the current Opus, Sonnet and Fable models; older ones reject it.
    static func supportsEffort(_ model: String) -> Bool {
        let prefixes = ["claude-fable", "claude-mythos", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-sonnet-4-6", "claude-opus-4-5"]
        return prefixes.contains { model.hasPrefix($0) }
    }

    static func supportsServerFallback(_ model: String) -> Bool {
        ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
    }

    static func isUnsupportedFormat(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("output_config") || lowered.contains("format") || lowered.contains("structured")
    }
}

// MARK: - OpenAI

/// OpenAI through the Chat Completions API.
public struct OpenAIProvider: LLMProvider {
    public let kind = ProviderKind.openAI
    let apiKey: String
    let http: HTTPClient
    let baseURL: URL

    public init(apiKey: String, session: URLSession = .shared, baseURL: URL = URL(string: "https://api.openai.com/v1/")!) {
        self.apiKey = apiKey
        self.http = HTTPClient(provider: .openAI, session: session)
        self.baseURL = baseURL
    }

    public var contextCharacters: Int { 350_000 }

    private var headers: [String: String] { ["Authorization": "Bearer \(apiKey)"] }

    public func models() async throws -> [LLMModel] {
        let request = try HTTPClient.jsonRequest(baseURL.appendingPathComponent("models"), method: "GET", headers: headers, timeout: 30)
        let json = try await http.send(request)
        let excluded = ["audio", "realtime", "tts", "transcribe", "search", "image", "embedding", "instruct", "moderation", "whisper", "dall-e", "davinci", "babbage", "codex", "computer"]
        let ids = (json["data"]?.array ?? []).compactMap { $0["id"]?.string }.filter { id in
            (id.hasPrefix("gpt-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4")) && !excluded.contains { id.contains($0) }
        }
        guard !ids.isEmpty else { throw LLMError.noModels(.openAI) }
        return ids.sorted(by: Self.preferred).map { LLMModel(id: $0, name: $0) }
    }

    /// Newest family first; within it the general model before mini and nano variants; dated snapshots last.
    static func preferred(_ lhs: String, _ rhs: String) -> Bool {
        func family(_ id: String) -> Double {
            let digits = id.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
            return Double(digits) ?? 0
        }
        func penalty(_ id: String) -> Int {
            var value = 0
            if id.contains("nano") { value += 2 }
            if id.contains("mini") { value += 1 }
            if id.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { value += 3 }
            return value
        }
        let lhsGPT = lhs.hasPrefix("gpt-"), rhsGPT = rhs.hasPrefix("gpt-")
        if lhsGPT != rhsGPT { return lhsGPT }
        if family(lhs) != family(rhs) { return family(lhs) > family(rhs) }
        if penalty(lhs) != penalty(rhs) { return penalty(lhs) < penalty(rhs) }
        return lhs < rhs
    }

    public func complete(_ request: LLMRequest, model: String) async throws -> String {
        let formats: [JSONValue?] = request.schema.map { schema in
            [["type": "json_schema", "json_schema": ["name": "result", "strict": true, "schema": .object(schema)]], ["type": "json_object"], nil]
        } ?? [nil]
        var lastError: Error = LLMError.badResponse("")
        for format in formats {
            do {
                return try await send(request, model: model, format: format)
            } catch LLMError.server(_, 400, let message) {
                lastError = LLMError.server(.openAI, 400, message)
                continue
            }
        }
        throw lastError
    }

    private func send(_ request: LLMRequest, model: String, format: JSONValue?) async throws -> String {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "messages": [
                ["role": "system", "content": .string(request.system)],
                ["role": "user", "content": .string(request.prompt)],
            ],
        ]
        if let format { body["response_format"] = format }
        let urlRequest = try HTTPClient.jsonRequest(baseURL.appendingPathComponent("chat/completions"), headers: headers, body: .object(body))
        let json = try await http.send(urlRequest)
        guard let choice = json["choices"]?.array?.first else { throw LLMError.badResponse("Keine Antwort") }
        if let refusal = choice["message"]?["refusal"]?.string, !refusal.isEmpty { throw LLMError.refused(refusal) }
        switch choice["finish_reason"]?.string {
        case "length": throw LLMError.truncated
        case "content_filter": throw LLMError.refused("content_filter")
        default: break
        }
        guard let text = choice["message"]?["content"]?.string, !text.isEmpty else { throw LLMError.badResponse("Leere Antwort") }
        return text
    }
}

// MARK: - Google

/// Gemini through the Generative Language API.
public struct GeminiProvider: LLMProvider {
    public let kind = ProviderKind.google
    let apiKey: String
    let http: HTTPClient
    let baseURL: URL

    public init(apiKey: String, session: URLSession = .shared, baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta/")!) {
        self.apiKey = apiKey
        self.http = HTTPClient(provider: .google, session: session)
        self.baseURL = baseURL
    }

    public var contextCharacters: Int { 900_000 }

    private var headers: [String: String] { ["x-goog-api-key": apiKey] }

    public func models() async throws -> [LLMModel] {
        let request = try HTTPClient.jsonRequest(baseURL.appendingPathComponent("models").appending(queryItems: [URLQueryItem(name: "pageSize", value: "200")]), method: "GET", headers: headers, timeout: 30)
        let json = try await http.send(request)
        let models = (json["models"]?.array ?? []).compactMap { item -> LLMModel? in
            guard let name = item["name"]?.string, name.contains("gemini"),
                  (item["supportedGenerationMethods"]?.array ?? []).contains(.string("generateContent")) else { return nil }
            let id = name.replacingOccurrences(of: "models/", with: "")
            let lowered = id.lowercased()
            if ["embedding", "image", "tts", "audio", "live", "vision"].contains(where: { lowered.contains($0) }) { return nil }
            return LLMModel(id: id, name: item["displayName"]?.string ?? id)
        }
        guard !models.isEmpty else { throw LLMError.noModels(.google) }
        return models.sorted { Self.preferred($0.id, $1.id) }
    }

    /// Newest version first; "flash" before "pro" before "lite"; previews and experiments last.
    static func preferred(_ lhs: String, _ rhs: String) -> Bool {
        func version(_ id: String) -> Double {
            Double(id.replacingOccurrences(of: "gemini-", with: "").prefix { $0.isNumber || $0 == "." }) ?? 0
        }
        func rank(_ id: String) -> Int {
            var value = 0
            if id.contains("preview") || id.contains("exp") { value += 10 }
            if id.contains("lite") { value += 2 } else if id.contains("pro") { value += 1 }
            return value
        }
        if version(lhs) != version(rhs) { return version(lhs) > version(rhs) }
        if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
        return lhs < rhs
    }

    public func complete(_ request: LLMRequest, model: String) async throws -> String {
        var generation: [String: JSONValue] = ["maxOutputTokens": .number(Double(request.maxOutputTokens))]
        if request.schema != nil { generation["responseMimeType"] = "application/json" }
        let body: JSONValue = [
            "systemInstruction": ["parts": [["text": .string(request.system)]]],
            "contents": [["role": "user", "parts": [["text": .string(request.prompt)]]]],
            "generationConfig": .object(generation),
        ]
        let path = "models/\(model):generateContent"
        let urlRequest = try HTTPClient.jsonRequest(baseURL.appendingPathComponent(path), headers: headers, body: body)
        let json = try await http.send(urlRequest)
        if let blocked = json["promptFeedback"]?["blockReason"]?.string { throw LLMError.refused(blocked) }
        guard let candidate = json["candidates"]?.array?.first else { throw LLMError.badResponse("Keine Antwort") }
        switch candidate["finishReason"]?.string {
        case "MAX_TOKENS": throw LLMError.truncated
        case "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST": throw LLMError.refused(candidate["finishReason"]?.string ?? "")
        default: break
        }
        let text = (candidate["content"]?["parts"]?.array ?? [])
            .filter { $0["thought"] != .bool(true) }
            .compactMap { $0["text"]?.string }
            .joined()
        guard !text.isEmpty else { throw LLMError.badResponse("Leere Antwort") }
        return text
    }
}

// MARK: - Ollama

/// A model running locally in Ollama. Nothing leaves the Mac.
public struct OllamaProvider: LLMProvider {
    public let kind = ProviderKind.ollama
    let baseURL: URL
    let http: HTTPClient
    /// Context window requested from Ollama, in tokens.
    let contextTokens: Int

    public static let defaultURL = URL(string: "http://localhost:11434")!

    public init(baseURL: URL = OllamaProvider.defaultURL, session: URLSession = .shared, contextTokens: Int = 16_384) {
        self.baseURL = baseURL
        self.http = HTTPClient(provider: .ollama, session: session)
        self.contextTokens = contextTokens
    }

    /// Leaves room for instructions and the answer within the context window.
    public var contextCharacters: Int { contextTokens * 2 }

    public func version() async throws -> String {
        let request = try HTTPClient.jsonRequest(baseURL.appendingPathComponent("api/version"), method: "GET", timeout: 5)
        return try await http.send(request, retries: 0)["version"]?.string ?? ""
    }

    public func models() async throws -> [LLMModel] {
        let request = try HTTPClient.jsonRequest(baseURL.appendingPathComponent("api/tags"), method: "GET", timeout: 10)
        let json = try await http.send(request, retries: 0)
        let models = (json["models"]?.array ?? []).compactMap { item -> LLMModel? in
            guard let name = item["name"]?.string ?? item["model"]?.string else { return nil }
            if name.contains("embed") { return nil }
            return LLMModel(id: name, name: name)
        }
        guard !models.isEmpty else { throw LLMError.noModels(.ollama) }
        return models
    }

    public func complete(_ request: LLMRequest, model: String) async throws -> String {
        do {
            return try await send(request, model: model, think: false)
        } catch LLMError.server(_, _, let message) where message.lowercased().contains("think") {
            // Older Ollama versions or models without a thinking switch: ask without it.
            return try await send(request, model: model, think: nil)
        }
    }

    private func send(_ request: LLMRequest, model: String, think: Bool?) async throws -> String {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": false,
            "messages": [
                ["role": "system", "content": .string(request.system)],
                ["role": "user", "content": .string(request.prompt)],
            ],
            "options": ["num_ctx": .number(Double(contextTokens)), "temperature": .number(0.2)],
        ]
        if let schema = request.schema { body["format"] = .object(schema) }
        // Thinking models would reason at length before every summary; the summary doesn't need it.
        if let think { body["think"] = .bool(think) }
        // Local models can take minutes on long transcripts.
        let urlRequest = try HTTPClient.jsonRequest(baseURL.appendingPathComponent("api/chat"), body: .object(body), timeout: 900)
        let json = try await http.send(urlRequest, retries: 0)
        if let error = json["error"]?.string { throw LLMError.server(.ollama, 500, error) }
        guard let text = json["message"]?["content"]?.string else { throw LLMError.badResponse("Keine Antwort") }
        if json["done_reason"]?.string == "length" { throw LLMError.truncated }
        let cleaned = Self.strippingThinking(text)
        guard !cleaned.isEmpty else { throw LLMError.badResponse("Leere Antwort") }
        return cleaned
    }

    static func strippingThinking(_ text: String) -> String {
        var result = text
        while let start = result.range(of: "<think>"), let end = result.range(of: "</think>", range: start.upperBound..<result.endIndex) {
            result.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
