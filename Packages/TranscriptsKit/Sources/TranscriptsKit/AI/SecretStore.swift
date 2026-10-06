import Foundation
import os
import Security

/// Where API keys live.
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ value: String?, for account: String) throws
}

/// API keys in the macOS keychain, readable only by this app.
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = "com.lukaskbl.Transcripts.api-keys") {
        self.service = service
    }

    public func secret(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = "Transcripts – \(account)"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Der API-Key konnte nicht im Schlüsselbund gespeichert werden (\(status))."])
        }
    }
}

/// Keys held in memory, for tests and the demo mode.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func secret(for account: String) -> String? {
        lock.withLock { values[account] }
    }

    public func setSecret(_ value: String?, for account: String) throws {
        lock.withLock { values[account] = value }
    }
}
