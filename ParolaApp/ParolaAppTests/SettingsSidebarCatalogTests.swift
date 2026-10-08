import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore

@Suite("Settings sidebar catalog")
struct SettingsSidebarCatalogTests {
    @Test("repeated evaluations produce the same groups")
    func repeatedEvaluationsMatch() {
        let first = SettingsSidebarCatalog.visibleGroups(features: .all, search: "")
        let second = SettingsSidebarCatalog.visibleGroups(features: .all, search: "")
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.routes) == second.map(\.routes))
    }

    @Test("App and Support wear grey, every other group a colour of its own")
    func everyGroupHasATint() {
        let ids = SettingsSidebarCatalog.all.map(\.id)
        let coloured = ids.filter { $0 != "start" && $0 != "end" }
        let tints = coloured.map { DS.settingsGroupTint(for: $0) }
        #expect(Set(tints).count == coloured.count)
        #expect(!tints.contains(.gray))
        #expect(DS.settingsGroupTint(for: "start") == .gray)
        #expect(DS.settingsGroupTint(for: "end") == .gray)
    }

    @Test("no group's tile is red, the colour that means recording")
    func noGroupIsRed() {
        for id in SettingsSidebarCatalog.all.map(\.id) {
            let tint = NSColor(DS.settingsGroupTint(for: id)).usingColorSpace(.sRGB)
            let hue = tint?.hueComponent ?? 0
            let saturation = tint?.saturationComponent ?? 0
            #expect(saturation < 0.3 || (hue > 0.04 && hue < 0.94), "\(id): hue \(hue)")
        }
    }

    @Test("an id the catalog never uses falls back to the neutral tint")
    func unknownGroupIsNeutral() {
        #expect(DS.settingsGroupTint(for: "nope") == DS.settingsGroupTint(for: "end"))
    }

    @Test("group ids are unique")
    func groupIDsAreUnique() {
        let ids = SettingsSidebarCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test("a filtered group keeps its id when its first route drops out")
    func filteringKeepsGroupIDs() {
        let unfiltered = SettingsSidebarCatalog.visibleGroups(features: .all, search: "")
        let filtered = SettingsSidebarCatalog.visibleGroups(features: .all, search: "translation")
        #expect(unfiltered.contains { $0.id == "transcription" && $0.routes.first == .localModels })
        let hit = filtered.first { $0.routes.contains(.translation) }
        #expect(hit?.id == "transcription")
        #expect(hit?.routes.first != .localModels)
    }

    @Test("typing one character at a time never renames a surviving group")
    func incrementalTypingKeepsGroupIDs() {
        let query = "export"
        var typed = ""
        for character in query {
            typed.append(character)
            let groups = SettingsSidebarCatalog.visibleGroups(features: .all, search: typed)
            for group in groups {
                #expect(SettingsSidebarCatalog.all.contains { $0.id == group.id })
            }
        }
        #expect(SettingsSidebarCatalog.visibleGroups(features: .all, search: typed)
            .contains { $0.id == "export" })
    }

    @Test("hiding features drops groups without renaming the rest")
    func featureGatingKeepsGroupIDs() {
        let groups = SettingsSidebarCatalog.visibleGroups(features: FeatureSet(enabled: []), search: "")
        #expect(!groups.contains { $0.id == "dictation" })
        #expect(!groups.contains { $0.id == "capture" })
        #expect(groups.contains { $0.id == "start" && $0.routes.first == .general })
        #expect(groups.contains { $0.id == "end" && $0.routes.first == .advanced })
    }

    @Test("search covers labels, extra keywords and scope keywords")
    func searchCoversEveryTermSource() {
        #expect(SettingsSidebarCatalog.matches(route: .dictation, query: "dictation"))
        #expect(SettingsSidebarCatalog.matches(route: .localModels, query: "parakeet"))
        #expect(SettingsSidebarCatalog.matches(route: .exportFormats, query: "srt"))
        #expect(!SettingsSidebarCatalog.matches(route: .advanced, query: "srt"))
    }
}

@Suite("Settings pane summaries")
struct SettingsPaneSummaryTests {
    @Test("every pane explains itself in one sentence")
    func everyRouteHasASummary() {
        for route in SettingsRoute.allCases {
            let summary = route.summary
            #expect(!summary.isEmpty, "\(route.rawValue) has no summary")
            #expect(summary != route.label, "\(route.rawValue) summary repeats its title")
            #expect(summary.hasSuffix("."), "\(route.rawValue) summary is not a sentence")
        }
    }

    @Test("summaries are searchable from the sidebar")
    func summaryFeedsSearch() {
        let hits = SettingsSidebarCatalog.visibleGroups(features: .all, search: "hotkey")
            .flatMap(\.routes)
        #expect(hits.contains(.dictation))
    }
}
