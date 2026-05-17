import Foundation

/// Reads MDM-pushed configuration from the standard `com.apple.configuration.managed`
/// UserDefaults domain. All accessors are nil/false when no policy is set.
// UserDefaults isn't Sendable but is thread-safe on Darwin; this struct only reads from it.
public struct ManagedConfiguration: @unchecked Sendable {
    public enum Key: String, Sendable, CaseIterable {
        case defaultModel
        case allowedEngines
        case disableYouTubeIngestion
        case disableDictation
        case disableCloudLLM
        case disableModelDownloads
        case requireEnglishOnly
    }

    private let storage: UserDefaults
    private let domainKey: String

    public init(
        storage: UserDefaults = .standard,
        domainKey: String = "com.apple.configuration.managed"
    ) {
        self.storage = storage
        self.domainKey = domainKey
    }

    public static let shared = ManagedConfiguration()

    private var managedDict: [String: Any]? {
        storage.dictionary(forKey: domainKey)
    }

    public var defaultModel: String? {
        managedDict?[Key.defaultModel.rawValue] as? String
    }

    public var allowedEngines: [EngineID]? {
        guard let raw = managedDict?[Key.allowedEngines.rawValue] as? [String] else {
            return nil
        }
        return raw.map { EngineID($0) }
    }

    public var disableYouTubeIngestion: Bool {
        managedDict?[Key.disableYouTubeIngestion.rawValue] as? Bool ?? false
    }

    public var disableDictation: Bool {
        managedDict?[Key.disableDictation.rawValue] as? Bool ?? false
    }

    public var disableCloudLLM: Bool {
        managedDict?[Key.disableCloudLLM.rawValue] as? Bool ?? false
    }

    public var disableModelDownloads: Bool {
        managedDict?[Key.disableModelDownloads.rawValue] as? Bool ?? false
    }

    public var requireEnglishOnly: Bool {
        managedDict?[Key.requireEnglishOnly.rawValue] as? Bool ?? false
    }

    /// True if any managed policy is active. Useful for showing a "Managed device" banner.
    public var isActive: Bool {
        guard let dict = managedDict else { return false }
        return !dict.isEmpty
    }

    /// Returns whether the given key is currently being enforced (i.e. has a value in the managed dict).
    public func isManaged(_ key: Key) -> Bool {
        managedDict?[key.rawValue] != nil
    }

    /// Filters a list of model variants by the managed engine allowlist. No-op if no allowlist set.
    public func filterAllowed(_ variants: [ModelVariant]) -> [ModelVariant] {
        guard let allowed = allowedEngines else { return variants }
        let allowedSet = Set(allowed)
        return variants.filter { allowedSet.contains($0.engineID) }
    }
}
