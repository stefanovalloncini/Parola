import Foundation
import Security

public protocol APIKeyStore: Sendable {
    func get(for provider: CloudLLMProviderID) async throws -> String?
    func set(_ value: String?, for provider: CloudLLMProviderID) async throws
}

public actor KeychainAPIKeyStore: APIKeyStore {
    private let service: String

    public init(service: String = "app.parola.cloudllm") {
        self.service = service
    }

    public static let shared = KeychainAPIKeyStore()

    public func get(for provider: CloudLLMProviderID) async throws -> String? {
        let account = providerAccount(provider)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: kCFBooleanTrue!
        ]
        if ProcessInfo.processInfo.environment["PAROLA_KEYCHAIN_USE_DATA_PROTECTION"] != nil {
            query[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            ParolaLog.error(.ai, "keychain read failed with OSStatus \(Int(status))")
            throw ParolaError.ioError("Keychain read failed: \(status)")
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ParolaError.ioError("Keychain returned malformed data")
        }
        return value
    }

    public func set(_ value: String?, for provider: CloudLLMProviderID) async throws {
        let account = providerAccount(provider)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let value, !value.isEmpty {
            let data = Data(value.utf8)
            let attributes: [String: Any] = [kSecValueData as String: data]
            let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var add = baseQuery
                add[kSecValueData as String] = data
                let addStatus = SecItemAdd(add as CFDictionary, nil)
                if addStatus == errSecDuplicateItem {
                    let retry = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
                    guard retry == errSecSuccess else {
                        ParolaLog.error(.ai, "keychain update failed with OSStatus \(Int(retry))")
                        throw ParolaError.ioError("Keychain update failed: \(retry)")
                    }
                } else if addStatus != errSecSuccess {
                    ParolaLog.error(.ai, "keychain add failed with OSStatus \(Int(addStatus))")
                    throw ParolaError.ioError("Keychain add failed: \(addStatus)")
                }
            } else if status != errSecSuccess {
                ParolaLog.error(.ai, "keychain update failed with OSStatus \(Int(status))")
                throw ParolaError.ioError("Keychain update failed: \(status)")
            }
        } else {
            let status = SecItemDelete(baseQuery as CFDictionary)
            if status != errSecSuccess && status != errSecItemNotFound {
                ParolaLog.error(.ai, "keychain delete failed with OSStatus \(Int(status))")
                throw ParolaError.ioError("Keychain delete failed: \(status)")
            }
        }
    }

    private func providerAccount(_ provider: CloudLLMProviderID) -> String {
        CloudLLMProviderInfo.info(for: provider)?.keychainAccount ?? "app.parola.cloudllm.\(provider.rawValue)"
    }
}

public actor InMemoryAPIKeyStore: APIKeyStore {
    private var keys: [CloudLLMProviderID: String] = [:]
    public init(keys: [CloudLLMProviderID: String] = [:]) {
        self.keys = keys
    }
    public func get(for provider: CloudLLMProviderID) async throws -> String? {
        keys[provider]
    }
    public func set(_ value: String?, for provider: CloudLLMProviderID) async throws {
        if let value, !value.isEmpty {
            keys[provider] = value
        } else {
            keys.removeValue(forKey: provider)
        }
    }
}
