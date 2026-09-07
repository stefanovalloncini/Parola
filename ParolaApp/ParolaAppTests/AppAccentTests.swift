import Foundation
import Testing
@testable import Parola
import ParolaTestSupport

@Suite("App accent", .serialized)
struct AppAccentTests {

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let previous = DefaultsStore.current
        let suite = temporaryDefaults("test-accent-")
        DefaultsStore.current = suite
        defer { DefaultsStore.current = previous }
        try body(suite)
    }

    @Test("every case has a non-empty label and a stable id")
    func labelsAndIds() {
        for accent in AppAccent.allCases {
            #expect(accent.label.isEmpty == false)
            #expect(accent.id == accent.rawValue)
        }
    }

    @Test("labels map to their plain names")
    func labelMapping() {
        #expect(AppAccent.terracotta.label == "Terracotta")
        #expect(AppAccent.blue.label == "Blue")
        #expect(AppAccent.graphite.label == "Graphite")
    }

    @Test("storage key is the documented defaults key")
    func storageKey() {
        #expect(AppAccent.storageKey == "appAccentColor")
    }

    @Test("current defaults to terracotta when nothing is stored")
    func currentDefault() {
        withDefaults { _ in
            #expect(AppAccent.current == .terracotta)
        }
    }

    @Test("current reads a stored raw value")
    func currentReadsStored() {
        withDefaults { defaults in
            defaults.set("purple", forKey: AppAccent.storageKey)
            #expect(AppAccent.current == .purple)
        }
    }

    @Test("current falls back to terracotta for an unrecognized raw value")
    func currentRejectsGarbage() {
        withDefaults { defaults in
            defaults.set("chartreuse", forKey: AppAccent.storageKey)
            #expect(AppAccent.current == .terracotta)
        }
    }

    @Test("every raw value resolves back through the initializer")
    func rawValueRoundTrip() {
        for accent in AppAccent.allCases {
            #expect(AppAccent(rawValue: accent.rawValue) == accent)
        }
    }
}
