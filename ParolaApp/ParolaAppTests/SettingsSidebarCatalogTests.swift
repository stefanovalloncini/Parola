import Foundation
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
        #expect(!SettingsSidebarCatalog.matches(route: .about, query: "srt"))
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
