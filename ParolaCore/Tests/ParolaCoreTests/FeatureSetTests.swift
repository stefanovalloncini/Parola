import Foundation
import Testing
@testable import ParolaCore

@Suite("FeatureSet resolution")
struct FeatureSetTests {
    private func makeManaged(_ dict: [String: Any]?) -> ManagedConfiguration {
        let suite = "feature-set-tests-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        if let dict { store.set(dict, forKey: "test.managed") }
        return ManagedConfiguration(storage: store, domainKey: "test.managed")
    }

    @Test func absentDictEnablesEverything() {
        let set = FeatureSet.resolve(managed: makeManaged(nil))
        #expect(set == .all)
    }

    @Test func allowlistEnablesExactlyThoseUnits() {
        let set = FeatureSet.resolve(managed: makeManaged(["enabledFeatures": ["dictation", "ai"]]))
        #expect(set.enabled == [.dictation, .ai])
        #expect(set.isEnabled(.dictation))
        #expect(!set.isEnabled(.youtube))
    }

    @Test func unknownNamesAreIgnored() {
        let set = FeatureSet.resolve(managed: makeManaged(["enabledFeatures": ["dictation", "hologram"]]))
        #expect(set.enabled == [.dictation])
    }

    @Test func emptyAllowlistDisablesAllUnits() {
        let set = FeatureSet.resolve(managed: makeManaged(["enabledFeatures": [String]()]))
        #expect(set.enabled.isEmpty)
    }

    @Test func legacyBooleansIntersectWithAllowlist() {
        let set = FeatureSet.resolve(managed: makeManaged([
            "enabledFeatures": ["dictation", "youtube", "batch"],
            "disableDictation": true,
            "disableYouTubeIngestion": true,
        ]))
        #expect(set.enabled == [.batch])
    }

    @Test func legacyBooleansAloneStillGate() {
        let set = FeatureSet.resolve(managed: makeManaged(["disableYouTubeIngestion": true]))
        #expect(!set.isEnabled(.youtube))
        #expect(set.isEnabled(.dictation))
    }

    @Test func requireThrowsTypedError() {
        let set = FeatureSet(enabled: [])
        #expect(throws: ParolaError.self) { try set.require(.batch) }
    }

    @Test func requirePassesWhenEnabled() throws {
        try FeatureSet.all.require(.batch)
    }

    @Test func errorCopyNamesTheFeature() {
        let error = ParolaError.featureDisabled(.youtube)
        #expect(error.description.contains("YouTube"))
        #expect(error.description.contains("disabled in this deployment"))
    }

    @Test func appDomainResolutionHonorsSuiteOverride() {
        let suite = "feature-set-env-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        store.set(["enabledFeatures": ["batch"]], forKey: "com.apple.configuration.managed")
        defer { store.removePersistentDomain(forName: suite) }
        let set = FeatureSet.resolveFromAppDomain(environment: ["PAROLA_MANAGED_SUITE": suite])
        #expect(set.enabled == [.batch])
    }
}
