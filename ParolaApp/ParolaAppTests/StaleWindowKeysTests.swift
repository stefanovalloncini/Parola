import Foundation
import Testing
@testable import Parola
import ParolaTestSupport

@Suite("Stale window frame keys")
struct StaleWindowKeysTests {

    private static let typeNamedWindow = "NSWindow Frame SwiftUI.WindowGroup<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<"
        + "SwiftUI.(unknown context at $1aad1d5c0).SceneBridgeReader<Parola.ContentView>>>>-1-AppWindow-1"
    private static let typeNamedSplitView = "NSSplitView Subview Frames SwiftUI.WindowGroup<SwiftUI.ModifiedContent<"
        + "SwiftUI.(unknown context at $1aad1d5c0).SceneBridgeReader<Parola.ContentView>>>-1-AppWindow-1, SidebarNavigationSplitView"
    private static let contentNamedWindow = "NSWindow Frame SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<"
        + "SwiftUI.IDView<Parola.ContentView, Swift.Int>>>-1-AppWindow-1"

    private static var kept: [String: Any] { [
        "NSWindow Frame main-AppWindow-1": "310 185 1180 760 0 0 1800 1130 ",
        "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView": [
            "0.000000, 0.000000, 240.000000, 760.000000, NO, NO",
            "240.000000, 0.000000, 940.000000, 760.000000, NO, NO",
        ],
        "NSWindow Frame com_apple_SwiftUI_Settings_window": "100 497 900 632 0 0 1800 1130 ",
        "NSWindow Frame transcript-AppWindow-1": "508 187 900 640 0 0 1800 1130 ",
        "NSSplitView Subview Frames NSColorPanelSplitView": ["0.000000, 0.000000, 224.000000, 258.000000, NO, NO"],
        "selectedModel": "openai_whisper-large-v3-v20240930_turbo",
        "dictationEnabled": true,
        "meetingDetectorEnabled": true,
    ] }

    @Test("type-named frames go; stable window, Settings, split-view keys and settings stay")
    func prunesOnlyTypeNamedFrames() throws {
        let name = temporarySuiteName()
        let defaults = try #require(UserDefaults(suiteName: name))
        let stale = [Self.typeNamedWindow, Self.typeNamedSplitView, Self.contentNamedWindow]
        for key in stale {
            defaults.set("166 94 1180 760 0 0 1512 949 ", forKey: key)
        }
        for (key, value) in Self.kept {
            defaults.set(value, forKey: key)
        }

        let removed = StaleWindowKeys.prune(domain: name)

        let left = defaults.persistentDomain(forName: name) ?? [:]
        #expect(removed == stale.count)
        #expect(Set(left.keys) == Set(Self.kept.keys))
        #expect(left["NSWindow Frame main-AppWindow-1"] as? String == "310 185 1180 760 0 0 1800 1130 ")
        #expect(left["selectedModel"] as? String == "openai_whisper-large-v3-v20240930_turbo")
        #expect(left["dictationEnabled"] as? Bool == true)
    }

    @Test("a domain with nothing stale is left as it was")
    func cleanDomainIsUntouched() throws {
        let name = temporarySuiteName()
        let defaults = try #require(UserDefaults(suiteName: name))
        for (key, value) in Self.kept {
            defaults.set(value, forKey: key)
        }

        let removed = StaleWindowKeys.prune(domain: name)

        let left = defaults.persistentDomain(forName: name) ?? [:]
        #expect(removed == 0)
        #expect(Set(left.keys) == Set(Self.kept.keys))
    }

    @Test("only the two type-named prefixes count as stale")
    func stalePrefixes() {
        #expect(StaleWindowKeys.isStale(Self.typeNamedWindow))
        #expect(StaleWindowKeys.isStale(Self.typeNamedSplitView))
        #expect(StaleWindowKeys.isStale(Self.contentNamedWindow))
        #expect(!StaleWindowKeys.isStale("NSWindow Frame main-AppWindow-1"))
        #expect(!StaleWindowKeys.isStale("NSWindow Frame com_apple_SwiftUI_Settings_window"))
        #expect(!StaleWindowKeys.isStale("NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView"))
        #expect(!StaleWindowKeys.isStale("NSToolbar Configuration SwiftUI.WindowGroup<Parola.ContentView>"))
        #expect(!StaleWindowKeys.isStale("selectedModel"))
    }
}
