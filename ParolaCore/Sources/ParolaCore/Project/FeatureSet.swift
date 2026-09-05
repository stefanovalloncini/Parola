import Foundation

/// One switchable unit of app functionality for deployment gating.
public enum ParolaFeature: String, CaseIterable, Sendable, Codable {
    case dictation
    case meetings
    case micRecording
    case liveCaptions
    case youtube
    case batch
    case ai
    case automation
    case watchedFolders

    public var displayName: String {
        switch self {
        case .dictation: return "Dictation"
        case .meetings: return "Meeting recording"
        case .micRecording: return "Microphone recording"
        case .liveCaptions: return "Live Captions"
        case .youtube: return "YouTube ingestion"
        case .batch: return "Batch transcription"
        case .ai: return "AI"
        case .automation: return "Automation"
        case .watchedFolders: return "Watched folders"
        }
    }
}

/// The features a deployment enables. Resolved once at launch, immutable after.
public struct FeatureSet: Sendable, Equatable {
    public let enabled: Set<ParolaFeature>

    public static let all = FeatureSet(enabled: Set(ParolaFeature.allCases))

    public init(enabled: Set<ParolaFeature>) {
        self.enabled = enabled
    }

    public func isEnabled(_ feature: ParolaFeature) -> Bool {
        enabled.contains(feature)
    }

    public func require(_ feature: ParolaFeature) throws {
        guard isEnabled(feature) else { throw ParolaError.featureDisabled(feature) }
    }

    /// Unknown allowlist names are dropped so configs written for newer versions
    /// still resolve on older builds.
    public static func resolve(managed: ManagedConfiguration = .shared) -> FeatureSet {
        var enabled = Set(ParolaFeature.allCases)
        if let allowlist = managed.enabledFeatures {
            enabled.formIntersection(allowlist.compactMap(ParolaFeature.init(rawValue:)))
        }
        if managed.disableDictation { enabled.remove(.dictation) }
        if managed.disableYouTubeIngestion { enabled.remove(.youtube) }
        return FeatureSet(enabled: enabled)
    }

    /// Resolution for auxiliary processes (CLI, MCP server): they read the app's
    /// defaults domain so one config governs every frontend. Two test seams:
    /// `PAROLA_MANAGED_PLIST` points at a plist file holding the managed dict,
    /// `PAROLA_MANAGED_SUITE` names an alternate defaults suite.
    public static func resolveFromAppDomain(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> FeatureSet {
        if let plistPath = environment["PAROLA_MANAGED_PLIST"],
           let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] {
            return resolve(managed: ManagedConfiguration(plistOverride: dict))
        }
        let store = environment["PAROLA_MANAGED_SUITE"].flatMap(UserDefaults.init(suiteName:))
            ?? UserDefaults(suiteName: "app.parola.ParolaApp")
            ?? .standard
        return resolve(managed: ManagedConfiguration(storage: store))
    }
}

/// Which CLI subcommands a deployment exposes. Lives in core so tests reach it;
/// the parola target maps names to ParsableCommand types.
public enum CLISubcommandPolicy {
    public static func visible(features: FeatureSet) -> [String] {
        var names = ["transcribe"]
        if features.isEnabled(.micRecording) || features.isEnabled(.meetings) {
            names.append("record")
        }
        names += ["models", "engines", "open", "burn", "bench", "library", "diagnostics"]
        if features.isEnabled(.automation) {
            names.append("mcp")
        }
        return names
    }
}
