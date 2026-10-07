import Foundation

public struct GraphQLErrorItem: Decodable, Sendable, Hashable {
    public var message: String
    public var type: String?
}

public enum GitHubError: Error, LocalizedError, Sendable, Equatable {
    case noToken
    case unauthorized
    case offline(String)
    case rateLimited
    case http(Int, String)
    case graphql([GraphQLErrorItem])
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .noToken: String(localized: "Nicht mit GitHub verbunden.")
        case .unauthorized: String(localized: "GitHub hat die Anmeldung abgelehnt. Bitte neu verbinden.")
        case .offline(let detail): String(localized: "GitHub ist nicht erreichbar. \(detail)", comment: "the system's network error follows")
        case .rateLimited: String(localized: "GitHubs Anfragelimit ist erreicht. Gleich noch einmal versuchen.")
        case .http(let code, _): String(localized: "GitHub hat mit einem Fehler geantwortet (\(code)).", comment: "HTTP status code")
        case .graphql(let items): items.map(\.message).joined(separator: " ")
        case .decoding(let detail): String(localized: "Unerwartete Antwort von GitHub. \(detail)", comment: "technical detail follows")
        }
    }

    /// The thing the request referred to no longer exists (deleted, transferred, or access removed).
    public var isNotFound: Bool {
        if case .graphql(let items) = self {
            return items.contains { $0.type == "NOT_FOUND" }
        }
        return false
    }
}

public protocol GitHubTokenSource: Sendable {
    func token() async throws -> String
}

/// A fixed token, for checking one before it is saved and for tests.
public struct FixedToken: GitHubTokenSource {
    public var value: String
    public init(_ value: String) { self.value = value }
    public func token() async throws -> String { value }
}

/// Sends GraphQL queries to GitHub. Taken from Issues for GitHub.
public final class GraphQLClient: Sendable {
    private let tokenSource: any GitHubTokenSource
    private let session: URLSession
    private let endpoint = URL(string: "https://api.github.com/graphql")!

    public init(tokenSource: any GitHubTokenSource, session: URLSession? = nil) {
        self.tokenSource = tokenSource
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    private struct Envelope<T: Decodable>: Decodable {
        var data: T?
        var errors: [GraphQLErrorItem]?
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Runs a query or mutation. With `allowPartial`, a response that carries both data and errors
    /// (for example one inaccessible organisation) returns the data instead of throwing.
    public func run<T: Decodable>(
        _ query: String,
        variables: [String: Any?] = [:],
        allowPartial: Bool = false,
        as type: T.Type = T.self
    ) async throws -> T {
        let token = try await tokenSource.token()
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Transcripts-Mac", forHTTPHeaderField: "User-Agent")
        let cleaned = variables.mapValues { $0 ?? NSNull() }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": cleaned])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw GitHubError.offline(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.offline(String(localized: "Keine Antwort."))
        }
        switch http.statusCode {
        case 200: break
        case 401: throw GitHubError.unauthorized
        case 403, 429:
            let text = String(data: data, encoding: .utf8) ?? ""
            if http.value(forHTTPHeaderField: "x-ratelimit-remaining") == "0" || text.contains("rate limit") {
                throw GitHubError.rateLimited
            }
            throw GitHubError.http(http.statusCode, text)
        default:
            throw GitHubError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let envelope: Envelope<T>
        do {
            envelope = try Self.decoder.decode(Envelope<T>.self, from: data)
        } catch {
            // A failed mutation comes back as {"data": {"x": null}, "errors": [...]}, which may not decode as T.
            if let errors = try? Self.decoder.decode(Envelope<EmptyData>.self, from: data).errors, !errors.isEmpty {
                throw Self.classify(errors)
            }
            throw GitHubError.decoding(String(describing: error))
        }
        if let errors = envelope.errors, !errors.isEmpty {
            if allowPartial, let data = envelope.data { return data }
            throw Self.classify(errors)
        }
        guard let result = envelope.data else {
            throw GitHubError.decoding(String(localized: "Leere Antwort."))
        }
        return result
    }

    private struct EmptyData: Decodable {}

    private static func classify(_ errors: [GraphQLErrorItem]) -> GitHubError {
        if errors.contains(where: { $0.type == "RATE_LIMITED" }) { return .rateLimited }
        return .graphql(errors)
    }
}

/// GraphQL connections come as `{ nodes: [...] }`; inaccessible entries are null.
struct Nodes<T: Decodable>: Decodable {
    var nodes: [T?]?
    var items: [T] { (nodes ?? []).compactMap { $0 } }
}
