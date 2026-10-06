import Foundation

/// Reads MDM-pushed configuration from the standard `com.apple.configuration.managed` UserDefaults domain.
/// `@unchecked Sendable` is safe because this only reads from `UserDefaults`, which is thread-safe on Darwin.
public struct ManagedConfiguration: @unchecked Sendable {
    public enum Key: String, Sendable, CaseIterable {
        case defaultModel
        case allowedEngines
        case enabledFeatures
        case disableYouTubeIngestion
        case disableDictation
        case disableDestinations
        case disableCloudLLM
        case disableModelDownloads
        case requireEnglishOnly
    }

    private let storage: UserDefaults
    private let domainKey: String
    private let dictOverride: [String: Any]?

    public init(
        storage: UserDefaults = .standard,
        domainKey: String = "com.apple.configuration.managed"
    ) {
        self.storage = storage
        self.domainKey = domainKey
        self.dictOverride = nil
    }

    /// Backs the configuration with a fixed dict instead of defaults. Auxiliary
    /// processes use this for the `PAROLA_MANAGED_PLIST` file seam, which stays
    /// testable where cfprefsd won't relay dev-process writes.
    public init(plistOverride: [String: Any]) {
        self.storage = .standard
        self.domainKey = "com.apple.configuration.managed"
        self.dictOverride = plistOverride
    }

    public static let shared = ManagedConfiguration()

    private var managedDict: [String: Any]? {
        dictOverride ?? storage.dictionary(forKey: domainKey)
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

    /// Feature allowlist for deployments; absent means every feature is enabled.
    public var enabledFeatures: [String]? {
        managedDict?[Key.enabledFeatures.rawValue] as? [String]
    }

    public var disableYouTubeIngestion: Bool {
        managedDict?[Key.disableYouTubeIngestion.rawValue] as? Bool ?? false
    }

    public var disableDictation: Bool {
        managedDict?[Key.disableDictation.rawValue] as? Bool ?? false
    }

    /// Hides the Send To pane, its menus and the auto-send hook.
    public var disableDestinations: Bool {
        managedDict?[Key.disableDestinations.rawValue] as? Bool ?? false
    }

    public static let userPrivacyModeKey = "parola.userPrivacyMode"

    /// Override for the store holding the user's own privacy-mode toggle. The app points
    /// this at its suite-aware defaults at bootstrap so `shared` (built on .standard for
    /// the MDM dict) sees the toggle the Settings pane writes. Set once before any reader;
    /// UserDefaults is thread-safe on Darwin.
    nonisolated(unsafe) public static var userSettingsStore: UserDefaults?

    public var disableCloudLLM: Bool {
        policyDisablesCloudLLM || (Self.userSettingsStore ?? storage).bool(forKey: Self.userPrivacyModeKey)
    }

    /// The administrator's half of `disableCloudLLM`, without the user's own switch.
    public var policyDisablesCloudLLM: Bool {
        managedDict?[Key.disableCloudLLM.rawValue] as? Bool == true
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
