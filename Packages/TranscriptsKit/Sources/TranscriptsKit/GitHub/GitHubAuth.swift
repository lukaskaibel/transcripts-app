import Foundation

/// How the app signs in to GitHub.
public enum GitHubLoginMethod: String, Codable, Sendable {
    /// The token of an existing GitHub CLI login (`gh auth token`), as Issues for GitHub uses it on this Mac.
    case githubCLI
    /// A token from signing in on github.com with a code, kept in the keychain.
    case token
}

/// The GitHub token for every request, read once and kept in memory.
public actor GitHubTokenStore: GitHubTokenSource {
    static let account = "github"

    private let secrets: SecretStore
    private var method: GitHubLoginMethod?
    private var cached: String?

    public init(secrets: SecretStore, method: GitHubLoginMethod?) {
        self.secrets = secrets
        self.method = method
    }

    public func setMethod(_ method: GitHubLoginMethod?) {
        self.method = method
        cached = nil
    }

    public func token() async throws -> String {
        if let cached { return cached }
        let token: String
        switch method {
        case .githubCLI:
            token = try await GitHubCLI.token()
        case .token:
            guard let stored = secrets.secret(for: Self.account), !stored.isEmpty else { throw GitHubError.noToken }
            token = stored
        case nil:
            throw GitHubError.noToken
        }
        cached = token
        return token
    }

    /// Drops the in-memory copy so the next request reads it again (after a 401, for instance).
    public func invalidate() {
        cached = nil
    }
}

/// Reads the token of an existing GitHub CLI login.
public enum GitHubCLI {
    public static func executableURL() -> URL? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public static var isAvailable: Bool { executableURL() != nil }

    public static func token() async throws -> String {
        guard let url = executableURL() else { throw GitHubError.noToken }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = url
            process.arguments = ["auth", "token"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            process.terminationHandler = { process in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0, !token.isEmpty {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: GitHubError.noToken)
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GitHubError.noToken)
            }
        }
    }
}

/// GitHub's OAuth device flow: the user enters a short code on github.com and the app waits for the token.
public struct GitHubDeviceFlow: Sendable {
    public struct Code: Sendable, Equatable {
        public var deviceCode: String
        public var userCode: String
        public var verificationURL: URL
        public var interval: TimeInterval
        public var expiresAt: Date
    }

    public enum FlowError: Error, LocalizedError {
        case notConfigured
        case expired
        case denied
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notConfigured: String(localized: "Diesem Build fehlt die Client-ID einer GitHub-OAuth-App.")
            case .expired: String(localized: "Der Code ist abgelaufen. Bitte neu starten.")
            case .denied: String(localized: "Der Zugriff wurde auf GitHub abgelehnt.")
            case .failed(let detail): detail
            }
        }
    }

    public let clientID: String
    /// The same rights Issues for GitHub asks for: issues and projects, and the organisations' projects.
    public static let scopes = "repo project read:org"

    public init(clientID: String) {
        self.clientID = clientID
    }

    /// The client ID comes from the app's Info.plist key `GitHubClientID` (set `GITHUB_CLIENT_ID` in Local.xcconfig).
    public static var configuredClientID: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "GitHubClientID") as? String
        guard let value, !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    public func start() async throws -> Code {
        guard !clientID.isEmpty else { throw FlowError.notConfigured }
        let json = try await post("https://github.com/login/device/code", ["client_id": clientID, "scope": Self.scopes])
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw FlowError.failed((json["error_description"] as? String) ?? String(localized: "GitHub hat keinen Code geschickt."))
        }
        let interval = (json["interval"] as? Double) ?? 5
        let expires = (json["expires_in"] as? Double) ?? 900
        return Code(deviceCode: deviceCode, userCode: userCode, verificationURL: uri, interval: interval, expiresAt: Date().addingTimeInterval(expires))
    }

    /// Polls until the user approves on github.com, then returns the access token.
    public func waitForToken(_ code: Code) async throws -> String {
        var interval = code.interval
        while Date() < code.expiresAt {
            try await Task.sleep(for: .seconds(interval))
            let json = try await post("https://github.com/login/oauth/access_token", [
                "client_id": clientID,
                "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            ])
            if let token = json["access_token"] as? String { return token }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw FlowError.expired
            case "access_denied": throw FlowError.denied
            default: throw FlowError.failed((json["error_description"] as? String) ?? String(localized: "Die Anmeldung hat nicht geklappt."))
            }
        }
        throw FlowError.expired
    }

    private func post(_ url: String, _ form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}
