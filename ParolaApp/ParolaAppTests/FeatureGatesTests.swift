import AppKit
import Foundation
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

@Suite("Feature gates in the app")
@MainActor
struct FeatureGatesTests {
    private func makeIsolatedDefaults() -> UserDefaults {
        temporaryDefaults()
    }

    private func makeTempLibraryURL(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-gates-\(tag)-\(UUID().uuidString)")
    }

    private func makeModel(features: Set<ParolaFeature>) -> AppModel {
        AppModel(
            skipBootstrap: true,
            defaults: makeIsolatedDefaults(),
            libraryURL: makeTempLibraryURL("gates"),
            features: features
        )
    }

    @Test func excludedSideEffectsMapPerFeature() {
        let lean = FeatureSet(enabled: [.batch])
        let excluded = lean.excludedSideEffects(mode: .normal)
        #expect(excluded.contains(.dictationHotkey))
        #expect(excluded.contains(.meetingDetector))
        #expect(excluded.contains(.watchedFolders))
        #expect(excluded.contains(.refreshYtDlp))
        #expect(excluded.contains(.liveCaptionsTranslateRestore))
        #expect(excluded.contains(.automationBridge))
    }

    @Test func testModeKeepsTheBridge() {
        let none = FeatureSet(enabled: [])
        #expect(!none.excludedSideEffects(mode: .test).contains(.automationBridge))
    }

    @Test func fullSetExcludesNothing() {
        #expect(FeatureSet.all.excludedSideEffects(mode: .normal).isEmpty)
    }

    @Test func bootstrapParsesEnabledFeaturesFlag() {
        let bootstrap = AppBootstrap.test(from: ["--test-mode", "--enabled-features=dictation,ai"])
        #expect(bootstrap?.enabledFeaturesOverride == [.dictation, .ai])
    }

    @Test func bootstrapWithoutFlagHasNoOverride() {
        let bootstrap = AppBootstrap.test(from: ["--test-mode"])
        #expect(bootstrap?.enabledFeaturesOverride == nil)
    }

    @Test func modelResolvesOverrideIntoFeatures() {
        let model = makeModel(features: [.batch, .ai])
        #expect(model.features.enabled == [.batch, .ai])
    }

    @Test func recordingRefusalFailsThePhase() {
        let model = makeModel(features: [.batch])
        model.startRecording(source: .microphone)
        guard case .failed(let message) = model.phase else {
            Issue.record("expected failed phase, got \(model.phase)")
            return
        }
        #expect(message.contains("disabled in this deployment"))
    }

    @Test func systemAudioRefusalNamesMeetings() {
        let model = makeModel(features: [.micRecording])
        model.startRecording(source: .systemAudio)
        guard case .failed(let message) = model.phase else {
            Issue.record("expected failed phase, got \(model.phase)")
            return
        }
        #expect(message.contains("Meeting recording"))
    }

    @Test func youtubeRefusalFailsThePhase() {
        let model = makeModel(features: [.batch])
        model.transcribeYouTube(urlString: "https://youtu.be/x123")
        guard case .failed(let message) = model.phase else {
            Issue.record("expected failed phase, got \(model.phase)")
            return
        }
        #expect(message.contains("YouTube"))
    }

    @Test func multiFileDropRefusesBatchWhenGated() {
        let model = makeModel(features: [])
        model.startBatch(urls: [
            URL(fileURLWithPath: "/tmp/a.wav"),
            URL(fileURLWithPath: "/tmp/b.wav"),
        ])
        #expect(model.batchJobs.isEmpty)
        guard case .failed(let message) = model.phase else {
            Issue.record("expected failed phase, got \(model.phase)")
            return
        }
        #expect(message.contains("Batch"))
    }

    @Test func intentDictationStartDoesNotEnableWhenGated() {
        let model = makeModel(features: [.batch])
        model.startDictationFromIntent()
        #expect(model.dictationEnabled == false)
    }

    @Test func fullFeatureModelKeepsBatchWorking() {
        let model = makeModel(features: Set(ParolaFeature.allCases))
        model.startBatch(urls: [URL(fileURLWithPath: "/tmp/a.wav")])
        #expect(model.batchJobs.count == 1)
    }

    @Test func settingsRoutesHideWithTheirFeature() {
        let lean = FeatureSet(enabled: [.batch])
        #expect(!SettingsRoute.dictation.isVisible(features: lean))
        #expect(!SettingsRoute.snippets.isVisible(features: lean))
        #expect(!SettingsRoute.corrections.isVisible(features: lean))
        #expect(!SettingsRoute.recordMeetings.isVisible(features: lean))
        #expect(!SettingsRoute.liveCaptions.isVisible(features: lean))
        #expect(SettingsRoute.batchExport.isVisible(features: lean))
        #expect(!SettingsRoute.prompts.isVisible(features: lean))
        #expect(!SettingsRoute.automation.isVisible(features: lean))
        #expect(!SettingsRoute.watchedFolders.isVisible(features: lean))
        #expect(!SettingsRoute.microphone.isVisible(features: lean))
        #expect(SettingsRoute.general.isVisible(features: lean))
        #expect(SettingsRoute.exportFormats.isVisible(features: lean))
    }

    @Test func microphonePaneStaysWhenAnyMicFeatureIsOn() {
        #expect(SettingsRoute.microphone.isVisible(features: FeatureSet(enabled: [.liveCaptions])))
        #expect(SettingsRoute.microphone.isVisible(features: FeatureSet(enabled: [.dictation])))
        #expect(SettingsRoute.microphone.isVisible(features: FeatureSet(enabled: [.micRecording])))
    }

    @Test func integrationsPaneRequiresYouTube() {
        #expect(!SettingsRoute.integrations.isVisible(features: FeatureSet(enabled: [.batch])))
        #expect(SettingsRoute.integrations.isVisible(features: FeatureSet(enabled: [.youtube])))
    }

    @Test func generalPaneHidesStreamRowWithoutMicFeatures() {
        #expect(!GeneralPane.showsStreamMicrophoneRow(features: FeatureSet(enabled: [.batch, .youtube])))
        #expect(GeneralPane.showsStreamMicrophoneRow(features: FeatureSet(enabled: [.micRecording])))
        #expect(GeneralPane.showsStreamMicrophoneRow(features: FeatureSet(enabled: [.dictation])))
        #expect(GeneralPane.showsStreamMicrophoneRow(features: FeatureSet(enabled: [.liveCaptions])))
    }

    @Test func cheatSheetDropsGatedShortcuts() {
        let sections = ShortcutCatalog.sections(features: FeatureSet(enabled: [.batch]))
        let labels = sections.flatMap(\.entries).map(\.label)
        #expect(!labels.contains { $0.contains("Live Captions") })
        #expect(!labels.contains { $0.contains("Scratchpad") })
        #expect(!labels.contains { $0.contains("Presenter") })
        #expect(!labels.contains { $0.contains("Chat") })
        #expect(labels.contains { $0.contains("Find") })
    }

    @Test func cheatSheetKeepsEverythingWhenAllOn() {
        let sections = ShortcutCatalog.sections(features: .all)
        let labels = sections.flatMap(\.entries).map(\.label)
        #expect(labels.contains { $0.contains("Live Captions") })
        #expect(labels.contains { $0.contains("Chat") })
    }

    @Test func menuBarFallsBackWhenDictationGated() {
        let gatedAway = MenuBarController.Mode(
            showExtra: false, dictationEnabled: true, features: FeatureSet(enabled: [])
        )
        #expect(gatedAway == .hidden)
        let stillFull = MenuBarController.Mode(
            showExtra: true, dictationEnabled: true, features: FeatureSet(enabled: [])
        )
        #expect(stillFull == .full)
    }
}
