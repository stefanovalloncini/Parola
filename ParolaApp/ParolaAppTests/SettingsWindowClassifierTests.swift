import Foundation
import Testing
@testable import Parola

@Suite("closeSettings window guard")
struct SettingsWindowClassifierTests {

    @Test("the main WindowGroup window is never classified as settings")
    func mainWindowIsNeverSettings() {
        #expect(SettingsWindowClassifier.isSettings(
            identifier: "com.apple.SwiftUI.window-AB12",
            title: "",
            isMainWindow: true,
            isTitled: false
        ) == false)
    }

    @Test("the main window stays excluded even if it briefly reports a title")
    func mainWindowWithTitleStillExcluded() {
        #expect(SettingsWindowClassifier.isSettings(
            identifier: "com.apple.SwiftUI.window-AB12",
            title: "Parola",
            isMainWindow: true,
            isTitled: true
        ) == false)
    }

    @Test("the SwiftUI Settings scene window is classified by its identifier")
    func settingsIdentifierMatches() {
        #expect(SettingsWindowClassifier.isSettings(
            identifier: "com.apple.SwiftUI.Settings",
            title: "Parola Settings",
            isMainWindow: false,
            isTitled: true
        ))
    }

    @Test("a titled Settings window matches by title when the identifier is untagged")
    func settingsTitleFallbackMatches() {
        #expect(SettingsWindowClassifier.isSettings(
            identifier: nil,
            title: "Parola Settings",
            isMainWindow: false,
            isTitled: true
        ))
    }

    @Test("a Preferences-titled window also matches")
    func preferencesTitleMatches() {
        #expect(SettingsWindowClassifier.isSettings(
            identifier: nil,
            title: "Preferences",
            isMainWindow: false,
            isTitled: true
        ))
    }

    @Test("the mini player window is never classified as settings")
    func miniPlayerIsNeverSettings() {
        #expect(SettingsWindowClassifier.isSettings(
            identifier: "mini-player",
            title: "Mini Player",
            isMainWindow: false,
            isTitled: true
        ) == false)
    }

    @Test("an untitled non-main window is not settings")
    func untitledNonMainIsNotSettings() {
        #expect(SettingsWindowClassifier.isSettings(
            identifier: "com.apple.SwiftUI.window-CD34",
            title: "",
            isMainWindow: false,
            isTitled: false
        ) == false)
    }

    @Test("a tagged window whose transcript title names Settings is not settings")
    func taggedWindowIgnoresItsTitle() {
        #expect(SettingsWindowClassifier.isSettings(
            identifier: "com.apple.SwiftUI.window-AB12",
            title: "Settings walkthrough",
            isMainWindow: false,
            isTitled: true
        ) == false)
        #expect(SettingsWindowClassifier.isSettings(
            identifier: "transcript-window",
            title: "Preferences survey",
            isMainWindow: false,
            isTitled: true
        ) == false)
    }

    @Test("a transcript window titled with the file name is not settings")
    func transcriptWindowIsNotSettings() {
        #expect(SettingsWindowClassifier.isSettings(
            identifier: "transcript-window",
            title: "interview.m4a",
            isMainWindow: false,
            isTitled: true
        ) == false)
    }
}
