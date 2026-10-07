import Foundation

/// The services that can write summaries.
public enum ProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case anthropic
    case openAI
    case google
    case ollama

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .google: "Google"
        case .ollama: "Ollama"
        }
    }

    public var needsKey: Bool { self != .ollama }

    /// What a key of this service starts with, as a hint in the key field.
    public var keyPlaceholder: String {
        switch self {
        case .anthropic: "sk-ant-…"
        case .openAI: "sk-…"
        case .google: "AIza…"
        case .ollama: ""
        }
    }

    public var keyHelpURL: URL? {
        switch self {
        case .anthropic: URL(string: "https://platform.claude.com/settings/keys")
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .google: URL(string: "https://aistudio.google.com/apikey")
        case .ollama: URL(string: "https://ollama.com/download")
        }
    }
}

/// A model a provider offers.
public struct LLMModel: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One request to a language model: instructions, the material, and the JSON shape wanted back.
public struct LLMRequest: Sendable {
    public var system: String
    public var prompt: String
    /// A JSON Schema the answer must follow. Providers that can enforce it do; the others are asked to.
    public var schema: [String: JSONValue]?
    public var maxOutputTokens: Int

    public init(system: String, prompt: String, schema: [String: JSONValue]? = nil, maxOutputTokens: Int = 16_000) {
        self.system = system
        self.prompt = prompt
        self.schema = schema
        self.maxOutputTokens = maxOutputTokens
    }
}

public protocol LLMProvider: Sendable {
    var kind: ProviderKind { get }
    /// Models this account can use, best guesses first.
    func models() async throws -> [LLMModel]
    /// Sends the request and returns the model's text (JSON when a schema was given).
    func complete(_ request: LLMRequest, model: String) async throws -> String
    /// How many characters of transcript fit into one request comfortably.
    var contextCharacters: Int { get }
}

public enum LLMError: LocalizedError, Equatable {
    case missingKey(ProviderKind)
    case invalidKey(ProviderKind)
    case rateLimited(ProviderKind)
    case overloaded(ProviderKind)
    case refused(String)
    case truncated
    case server(ProviderKind, Int, String)
    case unreachable(ProviderKind, String)
    case badResponse(String)
    case noModels(ProviderKind)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let provider): String(localized: "Für \(provider.title) ist noch kein API-Key hinterlegt.")
        case .invalidKey(let provider): String(localized: "\(provider.title) hat den API-Key abgelehnt. Prüfe ihn in den Einstellungen.")
        case .rateLimited(let provider): String(localized: "\(provider.title) meldet zu viele Anfragen. Versuch es gleich noch einmal.")
        case .overloaded(let provider): String(localized: "\(provider.title) ist gerade überlastet. Versuch es gleich noch einmal.")
        case .refused(let reason): reason.isEmpty ? String(localized: "Das Modell hat die Anfrage abgelehnt.") : String(localized: "Das Modell hat die Anfrage abgelehnt (\(reason)).")
        case .truncated: String(localized: "Die Antwort war zu lang und wurde abgeschnitten.")
        case .server(let provider, let status, let message): message.isEmpty ? String(localized: "\(provider.title) antwortet mit Fehler \(status)") : String(localized: "\(provider.title) antwortet mit Fehler \(status): \(message)")
        case .unreachable(let provider, let message): String(localized: "\(provider.title) ist nicht erreichbar: \(message)")
        case .badResponse(let message): String(localized: "Die Antwort des Modells war unbrauchbar: \(message)")
        case .noModels(let provider): String(localized: "\(provider.title) bietet keine passenden Modelle an.")
        }
    }

    /// Worth trying again after a short wait.
    var isTransient: Bool {
        switch self {
        case .rateLimited, .overloaded, .unreachable: true
        case .server(_, let status, _): status >= 500
        default: false
        }
    }
}

// MARK: - JSON

/// A JSON value, for building request bodies and schemas without stringly typed dictionaries.
public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

// MARK: - HTTP

/// Shared plumbing for the providers: JSON in, JSON out, typed errors, a few retries.
struct HTTPClient: Sendable {
    let session: URLSession
    let provider: ProviderKind

    init(provider: ProviderKind, session: URLSession = .shared) {
        self.provider = provider
        self.session = session
    }

    func send(_ request: URLRequest, retries: Int = 2) async throws -> JSONValue {
        var attempt = 0
        while true {
            do {
                return try await sendOnce(request)
            } catch let error as LLMError where error.isTransient && attempt < retries {
                attempt += 1
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
        }
    }

    private func sendOnce(_ request: URLRequest) async throws -> JSONValue {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LLMError.unreachable(provider, error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw LLMError.badResponse(String(localized: "Keine HTTP-Antwort", comment: "why a language model's answer was unusable")) }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            let message = json.map(Self.errorMessage) ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            switch http.statusCode {
            case 401, 403: throw LLMError.invalidKey(provider)
            case 429: throw LLMError.rateLimited(provider)
            case 529, 503: throw LLMError.overloaded(provider)
            default: throw LLMError.server(provider, http.statusCode, message)
            }
        }
        guard let json else { throw LLMError.badResponse(String(data: data.prefix(200), encoding: .utf8) ?? "") }
        return json
    }

    /// The human-readable part of the error bodies the providers send.
    static func errorMessage(_ json: JSONValue) -> String {
        if let message = json["error"]?["message"]?.string { return message }
        if let message = json["error"]?.string { return message }
        if let message = json["message"]?.string { return message }
        return ""
    }

    static func jsonRequest(_ url: URL, method: String = "POST", headers: [String: String] = [:], body: JSONValue? = nil, timeout: TimeInterval = 300) throws -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }
}

/// Pulls the JSON object out of a model's answer, tolerating code fences, reasoning tags and prose around it.
public enum JSONExtraction {
    public static func object(from text: String) throws -> JSONValue {
        var cleaned = text
        if let range = cleaned.range(of: "</think>") {
            cleaned = String(cleaned[range.upperBound...])
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = cleaned.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = value {
            return value
        }
        // The outermost braces, ignoring braces inside strings.
        guard let start = cleaned.firstIndex(of: "{") else { throw LLMError.badResponse(String(localized: "Kein JSON gefunden", comment: "why a language model's answer was unusable")) }
        var depth = 0
        var inString = false
        var escaped = false
        var end: String.Index?
        var index = start
        while index < cleaned.endIndex {
            let character = cleaned[index]
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    end = index
                    break
                }
            }
            index = cleaned.index(after: index)
        }
        guard let end, let data = String(cleaned[start...end]).data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw LLMError.badResponse(String(localized: "Ungültiges JSON", comment: "why a language model's answer was unusable"))
        }
        return value
    }
}
