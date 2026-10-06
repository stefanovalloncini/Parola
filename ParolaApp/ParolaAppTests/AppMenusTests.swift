import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@MainActor
@Suite("App menus: names and places")
struct AppMenusTests {
    private func makeModel(_ label: String, features: Set<ParolaFeature> = Set(ParolaFeature.allCases)) -> AppModel {
        AppModel(bootstrap: AppBootstrap(
            mode: .test,
            library: makeTempLibraryURL(label),
            defaultsOverride: temporaryDefaults(),
            sideEffects: [],
            filePicker: TestFilePicker(),
            enabledFeaturesOverride: features
        ))
    }

    /// The items AppKit builds from a menu's content, as the menu bar shows them.
    private func items<Content: View>(_ content: Content) -> [NSMenuItem] {
        let menu = NSHostingMenu(rootView: content)
        menu.update()
        return menu.items
    }

    private func titles<Content: View>(_ content: Content) -> [String] {
        items(content).map { $0.isSeparatorItem ? "—" : $0.title }
    }

    @Test("File holds the + menu's ways in, under the + menu's names")
    func fileMenuMatchesTheNewMenu() {
        let everything = titles(FileCommands(model: makeModel("file-menu")))
        #expect(everything == [
            "New Recording", "New System Audio Recording", "—",
            "Open Files…", "Transcribe Link…", "Batch Transcribe…", "Open Recent", "Save As Parola Document…",
        ])
        let plain = titles(FileCommands(model: makeModel("file-menu-plain", features: [])))
        #expect(plain == ["Open Files…", "Open Recent", "Save As Parola Document…"])
    }

    @Test("Check for Updates… sits under About Parola, off in a build with no update feed")
    func checkForUpdatesInTheAppMenu() throws {
        let appInfo = items(AppInfoCommands(showAbout: {}))
        #expect(appInfo.map(\.title) == ["About Parola", "Check for Updates…"])
        let check = try #require(appInfo.last)
        #expect(check.isEnabled == SparkleUpdater.feedURLConfigured)
    }

    @Test("the releases page is the repository's")
    func releasesPage() {
        #expect(SupportLinks.releases.absoluteString == "https://github.com/stefanovalloncini/Parola/releases")
    }
}
