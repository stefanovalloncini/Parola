import Foundation
import Security

/// Where a destination keeps the values it must not write into its stored settings. The settings
/// hold a reference; the value lives here.
public protocol SecretStore: Sendable {
    func get(_ reference: String) async throws -> String?
    func set(_ value: String?, for reference: String) async throws
}

public extension SecretStore {
    func remove(_ references: [String]) async {
        for reference in references {
            try? await set(nil, for: reference)
        }
    }

    static func newReference() -> String {
        "delivery-secret-\(UUID().uuidString)"
    }
}

public actor KeychainSecretStore: SecretStore {
    public static let shared = KeychainSecretStore()

    private let service: String

    public init(service: String = "app.parola.delivery") {
        self.service = service
    }

    public func get(_ reference: String) async throws -> String? {
        var query = baseQuery(reference)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = kCFBooleanTrue
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            ParolaLog.error(.export, "keychain read failed with OSStatus \(Int(status))")
            throw ParolaError.ioError("Keychain read failed: \(status)")
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ParolaError.ioError("Keychain returned malformed data")
        }
        return value
    }

    public func set(_ value: String?, for reference: String) async throws {
        let query = baseQuery(reference)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                ParolaLog.error(.export, "keychain delete failed with OSStatus \(Int(status))")
                throw ParolaError.ioError("Keychain delete failed: \(status)")
            }
            return
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            ParolaLog.error(.export, "keychain write failed with OSStatus \(Int(status))")
            throw ParolaError.ioError("Keychain write failed: \(status)")
        }
    }

    private func baseQuery(_ reference: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
        ]
        if ProcessInfo.processInfo.environment["PAROLA_KEYCHAIN_USE_DATA_PROTECTION"] != nil {
            query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        }
        return query
    }
}

public actor InMemorySecretStore: SecretStore {
    private var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public func get(_ reference: String) async throws -> String? { values[reference] }

    public func set(_ value: String?, for reference: String) async throws {
        if let value, !value.isEmpty {
            values[reference] = value
        } else {
            values.removeValue(forKey: reference)
        }
    }

    public func references() -> Set<String> { Set(values.keys) }
}

/// Reads values typed into an editor that has not saved yet, and falls back to the real store.
public struct OverlaySecretStore: SecretStore {
    private let base: any SecretStore
    private let overrides: [String: String]

    public init(base: any SecretStore, overrides: [String: String]) {
        self.base = base
        self.overrides = overrides
    }

    public func get(_ reference: String) async throws -> String? {
        if let value = overrides[reference], !value.isEmpty { return value }
        return try await base.get(reference)
    }

    public func set(_ value: String?, for reference: String) async throws {
        try await base.set(value, for: reference)
    }
}
