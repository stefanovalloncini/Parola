import Testing
@testable import Parola

@Suite("App accent")
struct AppAccentTests {

    @Test("storage key is the documented defaults key")
    func storageKey() {
        #expect(AppAccent.storageKey == "appAccentColor")
    }

    @Test("every raw value resolves back through the initializer")
    func rawValueRoundTrip() {
        for accent in AppAccent.allCases {
            #expect(AppAccent(rawValue: accent.rawValue) == accent)
            #expect(accent.id == accent.rawValue)
        }
    }

    /// One stored string feeds both enums, so a case in one and not the other would silently resolve to the default.
    @Test("every case names a theme preset, in the same order, with the same default")
    func presetsAgree() {
        #expect(AppAccent.allCases.map(\.rawValue) == ThemePreset.allCases.map(\.rawValue))
        #expect(AppAccent.defaultAccent.rawValue == ThemePreset.defaultPreset.rawValue)
    }
}
