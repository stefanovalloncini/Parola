import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Parola
import ParolaCore
import ParolaTestSupport

extension TranscriberMockSuites {
    @MainActor
    @Suite("Record commands", .serialized)
    struct RecordCommandsTests {
        private func makeModel(features: Set<ParolaFeature>? = nil) -> AppModel {
            let model = AppModel(bootstrap: AppBootstrap(
                mode: .test, library: makeTempLibraryURL("record-commands"), defaultsOverride: temporaryDefaults(),
                sideEffects: [], filePicker: TestFilePicker(), clock: ContinuousClock(),
                enabledFeaturesOverride: features
            ))
            model.recordingCountInSeconds = 0
            model.freeDiskSpaceProvider = { 50_000_000_000 }
            return model
        }

        @Test("an idle app can start either kind of take")
        func idle() {
            let model = makeModel()
            #expect(model.canStartTake(.microphone))
            #expect(model.canStartTake(.systemAudio))
        }

        @Test("a take in progress blocks another start")
        func busy() async throws {
            let fixture = try makeLinkFixtureWAV()
            defer { try? FileManager.default.removeItem(at: fixture) }
            try await withMocksCleared(.audioSource) {
                await MockAudioSourceRegistry.shared.install(kind: .mic, fixtureURL: fixture)
                let model = makeModel()
                model.startRecording(source: .microphone)
                #expect(!model.canStartTake(.microphone), "a start still in flight counts as a take")
                #expect(!model.canStartTake(.systemAudio))

                let capturing = await waitUntil { model.takeInProgress }
                #expect(capturing)
                #expect(!model.canStartTake(.microphone))
                #expect(!model.canStartTake(.systemAudio))

                await model.discardTake()
                let ended = await waitUntil { !model.recordingActive }
                #expect(ended)
                #expect(model.canStartTake(.microphone))
            }
        }

        @Test("a source the deployment turned off can't start")
        func gatedSource() {
            let micOnly = makeModel(features: [.micRecording])
            #expect(micOnly.canStartTake(.microphone))
            #expect(!micOnly.canStartTake(.systemAudio))

            let meetingsOnly = makeModel(features: [.meetings])
            #expect(!meetingsOnly.canStartTake(.microphone))
            #expect(meetingsOnly.canStartTake(.systemAudio))
        }

        @Test("a quit winding the takes down refuses a new one")
        func quitPending() {
            let model = makeModel()
            model.quitPending = true
            #expect(!model.canStartTake(.microphone))
            #expect(!model.canStartTake(.systemAudio))
        }

        @Test("Record starts the microphone, or system audio when the microphone is turned off")
        func primarySource() {
            #expect(RecordControl.primarySource(features: .all) == .microphone)
            #expect(RecordControl.primarySource(features: FeatureSet(enabled: [.meetings, .dictation])) == .systemAudio)
            #expect(RecordControl.primarySource(features: FeatureSet(enabled: [.dictation, .liveCaptions])) == nil)
        }

        @Test("the modes menu shows only when it offers more than Record itself")
        func modesMenu() {
            #expect(RecordControl.offersModes(features: .all))
            #expect(RecordControl.offersModes(features: FeatureSet(enabled: [.micRecording, .meetings])))
            #expect(RecordControl.offersModes(features: FeatureSet(enabled: [.micRecording, .dictation])))
            #expect(!RecordControl.offersModes(features: FeatureSet(enabled: [.micRecording, .batch])))
            #expect(!RecordControl.offersModes(features: FeatureSet(enabled: [.meetings])))
        }

        @Test("the meeting item follows the running app the menu bar shows, not the alert's flag")
        func meetingItem() {
            let model = makeModel()
            model.detectedMeetingAppName = "Zoom"
            model.meetingDetectedApp = nil
            #expect(RecordControl.detectedMeetingApp(for: model) == "Zoom", "no alert has to be up")
            #expect(RecordControl.offersModes(features: FeatureSet(enabled: [.meetings]), detectedMeetingApp: "Zoom"))
            #expect(!RecordControl.offersModes(features: FeatureSet(enabled: [.micRecording]), detectedMeetingApp: "Zoom"))

            let gated = makeModel(features: [.micRecording])
            gated.detectedMeetingAppName = "Zoom"
            #expect(RecordControl.detectedMeetingApp(for: gated) == nil)
        }

        @Test("in test mode the Record control and the menu bar show the meeting app without starting the detector")
        func detectorStaysOff() {
            let model = makeModel()
            model.detectedMeetingAppName = "Zoom"
            model.showMenuBarExtra = true
            let host = NSHostingView(rootView: RecordControl().environment(model))
            host.frame = NSRect(x: 0, y: 0, width: 240, height: 44)
            host.layoutSubtreeIfNeeded()

            #expect(host.fittingSize.width > 0, "the control rendered")
            #expect(MenuBarController.snapshot(for: model).detectedMeetingApp == "Zoom")
            #expect(!model.meetingDetectorStarted)
        }
    }
}

@MainActor
@Suite("Record button chrome")
struct RecordButtonChromeTests {
    @Test("the record button wears the plain glass style, not the prominent one")
    func plainGlass() {
        let button = RecordControl.styledButton(action: {}, showsModes: false)
        let typeName = String(describing: type(of: button))
        #expect(typeName.contains("GlassButtonStyle"))
        #expect(!typeName.contains("Prominent"))
    }

    @Test("the dot is the recording red")
    func dotColor() {
        #expect(RecordButtonLabel.dotColor == DS.Color.recordingFill)
    }

    @Test("the dot dims when disabled")
    func dotDims() {
        #expect(RecordButtonLabel.contentOpacity(isEnabled: true) == 1)
        #expect(RecordButtonLabel.contentOpacity(isEnabled: false) == DS.Opacity.disabled)
    }
}

@Suite("Record commands in Italian")
struct RecordCommandsItalianTests {
    @Test("the recording commands and the New menu read in Italian")
    func italian() throws {
        let path = try #require(Bundle.main.path(forResource: "it", ofType: "lproj"))
        let italian = try #require(Bundle(path: path))
        #expect(String(localized: "New Recording", bundle: italian) == "Nuova registrazione")
        #expect(String(localized: "New System Audio Recording", bundle: italian) == "Nuova registrazione audio di sistema")
        #expect(String(localized: "System Audio", bundle: italian) == "Audio di sistema")
        #expect(String(localized: "Record \("Zoom") Meeting", bundle: italian) == "Registra riunione Zoom")
        #expect(String(localized: "Recording options", bundle: italian) == "Opzioni di registrazione")
        #expect(String(localized: "Transcribe Link…", bundle: italian) == "Trascrivi link…")
        #expect(String(localized: "Batch Transcribe…", bundle: italian) == "Trascrivi in batch…")
    }
}
