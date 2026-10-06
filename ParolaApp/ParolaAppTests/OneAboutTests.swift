import AppKit
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("One About", .serialized)
struct OneAboutTests {
    private func makeModel() -> AppModel {
        AppModel(skipBootstrap: true, defaults: temporaryDefaults(), libraryURL: makeTempLibraryURL("one-about"))
    }

    private func ids(of view: some View, model: AppModel, height: CGFloat = 900) -> [String] {
        let hosted = HostedWindow(view.environment(model), width: 620, height: height)
        defer { hosted.close() }
        return HostedAccessibility.elements(in: hosted.host).compactMap(\.identifier)
    }

    @Test("Settings has no About pane of its own")
    func noAboutPane() {
        #expect(SettingsRoute(rawValue: "about") == nil)
        let routes = SettingsSidebarCatalog.all.flatMap(\.routes).map(\.rawValue)
        #expect(!routes.contains("about"))
    }

    @Test("the About window carries Open Repository and Copy Version")
    func aboutWindowButtons() {
        let found = ids(of: AboutWindow(), model: makeModel())
        #expect(found.contains { $0.hasSuffix("About.Button.OpenRepository") })
        #expect(found.contains { $0.hasSuffix("About.Button.CopyVersion") })
    }

    @Test("Advanced holds the diagnostics: retention, Export…, Reveal in Finder and Delete")
    func advancedHoldsDiagnostics() {
        let found = ids(of: AdvancedPane(), model: makeModel(), height: 1400)
        for leaf in ["Advanced.Text.DiagnosticsRetention", "Advanced.Button.ExportDiagnostics",
                     "Advanced.Button.RevealDiagnostics", "Advanced.Button.DeleteDiagnostics"] {
            #expect(found.contains { $0.hasSuffix(leaf) }, "Advanced lacks \(leaf)")
        }
        #expect(SettingsSidebarCatalog.matches(route: .advanced, query: "diagnostics"))
    }

    @Test("each About credit title fits on one line in the About window")
    func creditTitlesDontWrap() throws {
        let rows = [
            AboutCredit(title: "Transcription", value: "WhisperKit · FluidAudio Parakeet · Apple Speech"),
            AboutCredit(title: "Models on disk", value: "3,2 GB"),
        ]
        let hosted = HostedWindow(AboutCredits(rows: rows).frame(width: 332, alignment: .leading), width: 332, height: 300)
        defer { hosted.close() }
        let elements = HostedAccessibility.elements(in: hosted.host)
        let short = try #require(elements.first { $0.words.contains(String(localized: "Transcription")) })
        let long = try #require(elements.first { $0.words.contains(String(localized: "Models on disk")) })
        #expect(abs(long.frame.height - short.frame.height) < 2, "Models on disk is \(long.frame.height) pt tall")
    }

    @Test("About's models line reads like Local Models' usage line, with no bare count")
    func modelsLine() {
        let summary = ModelsDiskSummary(count: 1, bytes: 3_270_000_000, earlierBytes: 0)
        #expect(AboutInfoView.modelsLine(summary) == summary.usageText)
        #expect(AboutInfoView.modelsLine(ModelsDiskSummary(count: 0, bytes: 0, earlierBytes: 0)) == nil)
    }
}
