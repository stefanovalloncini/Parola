import AppKit
import Foundation
import SwiftUI
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
        #expect(AppAccent.slate.label == "Slate")
        #expect(AppAccent.terracotta.label == "Terracotta")
        #expect(AppAccent.blue.label == "Blue")
        #expect(AppAccent.graphite.label == "Graphite")
    }

    @Test("storage key is the documented defaults key")
    func storageKey() {
        #expect(AppAccent.storageKey == "appAccentColor")
    }

    @Test("current defaults to slate when nothing is stored")
    func currentDefault() {
        withDefaults { _ in
            #expect(AppAccent.current == .slate)
            #expect(AppAccent.defaultAccent == .slate)
        }
    }

    /// The migration rule: a stored preset outranks the new default, terracotta included.
    @Test("current keeps a stored preset rather than moving it to the new default")
    func currentKeepsStoredPreset() {
        for accent in AppAccent.allCases {
            withDefaults { defaults in
                defaults.set(accent.rawValue, forKey: AppAccent.storageKey)
                #expect(AppAccent.current == accent)
            }
        }
    }

    @Test("current reads a stored raw value")
    func currentReadsStored() {
        withDefaults { defaults in
            defaults.set("purple", forKey: AppAccent.storageKey)
            #expect(AppAccent.current == .purple)
        }
    }

    @Test("current falls back to the default for an unrecognized raw value")
    func currentRejectsGarbage() {
        withDefaults { defaults in
            defaults.set("chartreuse", forKey: AppAccent.storageKey)
            #expect(AppAccent.current == .defaultAccent)
        }
    }

    @Test("every raw value resolves back through the initializer")
    func rawValueRoundTrip() {
        for accent in AppAccent.allCases {
            #expect(AppAccent(rawValue: accent.rawValue) == accent)
        }
    }

    /// One stored string feeds both enums, so a case in one and not the other would silently resolve to the default.
    @Test("every case names a theme preset, in the same order, with the same default")
    func presetsAgree() {
        #expect(AppAccent.allCases.map(\.rawValue) == ThemePreset.allCases.map(\.rawValue))
        #expect(AppAccent.defaultAccent.rawValue == ThemePreset.defaultPreset.rawValue)
        for accent in AppAccent.allCases {
            #expect(accent.preset.rawValue == accent.rawValue)
        }
    }

    @Test("the accent colour resolves to the preset's values, not the asset catalog's")
    func colorFollowsThePreset() throws {
        let aqua = try #require(NSAppearance(named: .aqua))
        let night = try #require(NSAppearance(named: .darkAqua))
        for accent in AppAccent.allCases {
            let expected = accent.preset.accent.appearanceVariants
            var light = RGBA(0, 0, 0)
            var dark = RGBA(0, 0, 0)
            aqua.performAsCurrentDrawingAppearance { light = RGBA(accent.color) }
            night.performAsCurrentDrawingAppearance { dark = RGBA(accent.color) }
            #expect(light.hex == expected.light.hex, "\(accent.rawValue) light")
            #expect(dark.hex == expected.dark.hex, "\(accent.rawValue) dark")
        }
    }
}
